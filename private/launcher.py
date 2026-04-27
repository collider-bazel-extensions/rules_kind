#!/usr/bin/env python3
"""
rules_kind launcher.

Reads RULES_KIND_MANIFEST (JSON) and performs the full kind cluster lifecycle:
  detect runtime (Docker or podman) → kind create cluster
  → kind get kubeconfig → wait for API server
  → kind load image-archive (images) → kubectl apply (manifests)
  → write $TEST_TMPDIR/<name>.env → signal.pause()
  → SIGTERM → kind delete cluster → exit 0

Container runtime:
  By default, Docker is used. If Docker is unavailable, podman is used
  automatically (KIND_EXPERIMENTAL_PROVIDER=podman). Rootless podman requires
  running under a systemd scope with Delegate=yes; the launcher handles this
  by re-executing itself via systemd-run when needed.
"""

import atexit
import dataclasses
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

def _log(msg):
    print(f"[rules_kind] {msg}", flush=True)


def _find_runfile(rel_path, workspace=""):
    """Resolve a Bazel short_path to an absolute path in the runfiles tree."""
    runfiles_dir = os.environ.get("RUNFILES_DIR", "")
    if not runfiles_dir:
        runfiles_dir = os.path.abspath(sys.argv[0]) + ".runfiles"

    if rel_path.startswith("../"):
        normalized = rel_path[3:]
    elif workspace:
        normalized = workspace + "/" + rel_path
    else:
        normalized = rel_path

    candidate = os.path.join(runfiles_dir, normalized)
    if os.path.exists(candidate):
        return os.path.abspath(candidate)

    raise FileNotFoundError(
        f"runfile not found: {rel_path!r}\n"
        f"  Looked in: {runfiles_dir}\n"
        f"  Normalized: {normalized}"
    )


def _ensure_executable(path):
    try:
        os.chmod(path, os.stat(path).st_mode | 0o111)
    except OSError:
        if not os.access(path, os.X_OK):
            raise


def _run(args, env=None, check=True, **kwargs):
    """Run a subprocess, print output on failure."""
    result = subprocess.run(
        args, capture_output=True, text=True, env=env, **kwargs)
    if check and result.returncode != 0:
        raise RuntimeError(
            f"command failed: {' '.join(str(a) for a in args)}\n"
            f"stdout: {result.stdout}\n"
            f"stderr: {result.stderr}"
        )
    return result


# ---------------------------------------------------------------------------
# Container runtime detection
# ---------------------------------------------------------------------------

def _detect_runtime():
    """Return ("docker", env_extras) or ("podman", env_extras).

    env_extras is a dict of environment variables to add to subprocess calls.
    For podman, includes KIND_EXPERIMENTAL_PROVIDER=podman.
    """
    docker_problem = None
    podman_problem = None

    # Check if Docker is available and responsive.
    try:
        result = subprocess.run(
            ["docker", "info"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            _log("using Docker as container runtime")
            return "docker", {}
        docker_problem = (
            f"docker info exited {result.returncode} "
            f"(daemon not running?): {(result.stderr or result.stdout).strip()[:200]}"
        )
    except FileNotFoundError:
        docker_problem = "docker binary not found in PATH"
    except subprocess.TimeoutExpired:
        docker_problem = "docker info timed out after 5 s (daemon hung?)"

    # Fall back to podman.
    try:
        result = subprocess.run(
            ["podman", "--runtime", "/usr/bin/crun", "info"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            _log("Docker unavailable, using podman as container runtime")
            return "podman", {"KIND_EXPERIMENTAL_PROVIDER": "podman"}
        podman_problem = (
            f"podman info exited {result.returncode}: "
            f"{(result.stderr or result.stdout).strip()[:200]}"
        )
    except FileNotFoundError:
        podman_problem = "podman binary not found in PATH"
    except subprocess.TimeoutExpired:
        podman_problem = "podman info timed out after 5 s"

    raise RuntimeError(
        "rules_kind requires a container runtime (Docker or podman) to run\n"
        "Kubernetes nodes. kind cannot start a cluster without one.\n"
        "\n"
        "What was tried:\n"
        f"  docker: {docker_problem}\n"
        f"  podman: {podman_problem}\n"
        "\n"
        "Install one of:\n"
        "  Docker  — https://docs.docker.com/engine/install/\n"
        "            Ubuntu/Debian: sudo apt install docker.io\n"
        "            Fedora/RHEL:   sudo dnf install docker\n"
        "  podman  — https://podman.io/docs/installation\n"
        "            Ubuntu/Debian: sudo apt install podman\n"
        "            Fedora/RHEL:   sudo dnf install podman\n"
        "\n"
        "After installing, verify with: docker info   or   podman info"
    )


def _is_in_systemd_delegation():
    """Return True if we are already running inside a delegated systemd scope."""
    # The INVOCATION_ID env var is set by systemd when running under a scope/service.
    return bool(os.environ.get("INVOCATION_ID"))


def _short_tmpdir_for_podman():
    """Override `$TMPDIR` with a short path so rootless podman's conmon-term
    unix-domain sockets stay under the kernel's 108-char `sun_path` limit.

    Creates a fresh directory directly under `/tmp` (NOT under the inherited
    `$TMPDIR` — `tempfile.mkdtemp()`'s default would use `$TMPDIR` as the
    parent, which is exactly the long path we're trying to escape). The
    directory is removed on launcher exit so we don't leak per-test cruft.
    """
    short = tempfile.mkdtemp(prefix="rules_kind-tmp-", dir="/tmp")
    os.environ["TMPDIR"] = short
    atexit.register(_best_effort_rmtree, short)
    _log(f"podman: TMPDIR shortened to {short} "
         f"(was {len(os.environ.get('TEST_TMPDIR', '?'))} chars)")


def _best_effort_rmtree(path):
    """Remove a directory tree, ignoring errors. Used in atexit handlers
    where the best we can do is try."""
    try:
        shutil.rmtree(path, ignore_errors=True)
    except Exception:
        pass


def _reexec_under_systemd():
    """Re-exec this process under systemd-run --scope --property=Delegate=yes."""
    _log("re-executing under systemd-run for rootless podman cgroup delegation…")

    env = os.environ.copy()

    # systemd-run --user needs XDG_RUNTIME_DIR and DBUS_SESSION_BUS_ADDRESS.
    # Bazel's sandbox may strip these; derive them from the real UID.
    uid = os.getuid()
    xdg = f"/run/user/{uid}"
    if not env.get("XDG_RUNTIME_DIR") and os.path.isdir(xdg):
        env["XDG_RUNTIME_DIR"] = xdg
    if not env.get("DBUS_SESSION_BUS_ADDRESS"):
        bus = f"unix:path={xdg}/bus"
        if os.path.exists(f"{xdg}/bus"):
            env["DBUS_SESSION_BUS_ADDRESS"] = bus

    cmd = [
        "systemd-run",
        "--scope",
        "--user",
        "--property=Delegate=yes",
        "--",
        sys.executable,
    ] + sys.argv
    os.execvpe(cmd[0], cmd, env)


# ---------------------------------------------------------------------------
# kind cluster lifecycle
# ---------------------------------------------------------------------------

def _allocate_cluster_name():
    return "kind-" + uuid.uuid4().hex[:12]


def _kind_env(runtime_env):
    """Merge runtime env extras into the current environment."""
    env = os.environ.copy()
    env.update(runtime_env)
    if "podman" in runtime_env.get("KIND_EXPERIMENTAL_PROVIDER", ""):
        # Ensure podman uses the correct OCI runtime.
        env.setdefault("KIND_EXPERIMENTAL_PROVIDER", "podman")
    return env


def _create_cluster(kind_bin, cluster_name, k8s_version, kind_config, env):
    cmd = [
        kind_bin, "create", "cluster",
        "--name", cluster_name,
        "--image", f"kindest/node:v{k8s_version}",
    ]
    if kind_config:
        cmd += ["--config", kind_config]
    _log(f"creating cluster {cluster_name} (k8s v{k8s_version})…")
    _run(cmd, env=env)
    _log(f"cluster {cluster_name} created")


def _get_kubeconfig(kind_bin, cluster_name, kubeconfig_path, env):
    result = _run([kind_bin, "get", "kubeconfig", "--name", cluster_name], env=env)
    with open(kubeconfig_path, "w") as f:
        f.write(result.stdout)
    _log(f"kubeconfig written to {kubeconfig_path}")


def _wait_apiserver_ready(kubectl_bin, kubeconfig, timeout=120):
    _log("waiting for API server…")
    deadline = time.monotonic() + timeout
    last_err = None
    while time.monotonic() < deadline:
        result = subprocess.run(
            [kubectl_bin, "cluster-info", "--kubeconfig", kubeconfig],
            capture_output=True, text=True,
        )
        if result.returncode == 0:
            _log("API server is ready")
            return
        last_err = result.stderr.strip() or result.stdout.strip()
        time.sleep(2)
    raise TimeoutError(
        f"API server did not become ready within {timeout}s.\n"
        f"Last error: {last_err}"
    )


def _get_api_server_url(kubectl_bin, kubeconfig):
    result = _run([
        kubectl_bin, "config", "view",
        "--kubeconfig", kubeconfig,
        "--minify",
        "-o", "jsonpath={.clusters[0].cluster.server}",
    ])
    return result.stdout.strip()


def _load_image(kind_bin, cluster_name, tarball_path, env):
    _log(f"loading image: {os.path.basename(tarball_path)}")
    _run([
        kind_bin, "load", "image-archive",
        tarball_path,
        "--name", cluster_name,
    ], env=env)


def _wait_default_serviceaccount(kubectl_bin, kubeconfig, timeout=60):
    """Wait for the default ServiceAccount in the default namespace.

    The controller-manager creates this asynchronously after the API server
    starts. Applying Pod manifests before it exists causes an admission error
    even when automountServiceAccountToken=false.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = subprocess.run(
            [kubectl_bin, "get", "serviceaccount", "default",
             "--namespace", "default", "--kubeconfig", kubeconfig],
            capture_output=True, text=True,
        )
        if result.returncode == 0:
            return
        time.sleep(1)
    raise TimeoutError(
        f"default ServiceAccount not created within {timeout}s")


def _apply_manifests(kubectl_bin, kubeconfig, manifest_files):
    for path in manifest_files:
        _log(f"applying: {os.path.basename(path)}")
        result = _run([
            kubectl_bin, "apply", "-f", path,
            "--kubeconfig", kubeconfig,
        ])
        if result.stdout.strip():
            _log(result.stdout.strip())


def _delete_cluster(kind_bin, cluster_name, env):
    _log(f"deleting cluster {cluster_name}…")
    try:
        _run([kind_bin, "delete", "cluster", "--name", cluster_name], env=env)
        _log("cluster deleted")
    except Exception as e:
        _log(f"warning: cluster deletion failed: {e}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

@dataclasses.dataclass
class _KindState:
    cluster_name:  str
    kubeconfig:    str
    apiserver_url: str
    kind_bin:      str
    kubectl_bin:   str


def main():
    manifest_path = os.environ.get("RULES_KIND_MANIFEST", "")
    if not manifest_path:
        print("[rules_kind] ERROR: RULES_KIND_MANIFEST is not set", file=sys.stderr)
        sys.exit(1)

    cluster_target_name = os.environ.get("RULES_KIND_CLUSTER_TARGET_NAME", "kind_cluster")
    test_tmpdir = os.environ.get("TEST_TMPDIR") or tempfile.mkdtemp()

    with open(manifest_path) as f:
        m = json.load(f)

    workspace = m["workspace"]

    kind_bin    = _find_runfile(m["kind_bin"],    workspace)
    kubectl_bin = _find_runfile(m["kubectl_bin"], workspace)
    _ensure_executable(kind_bin)
    _ensure_executable(kubectl_bin)

    k8s_version      = m.get("k8s_version", "1.29")
    k8s_node_version = m.get("k8s_node_version", k8s_version)

    kind_config = None
    if "kind_config" in m:
        kind_config = _find_runfile(m["kind_config"], workspace)

    # Detect container runtime (Docker or podman).
    runtime, runtime_env = _detect_runtime()

    # Rootless podman requires a delegated systemd cgroup scope.
    if runtime == "podman" and not _is_in_systemd_delegation():
        _reexec_under_systemd()
        # If _reexec_under_systemd returns (it shouldn't — it calls execvpe),
        # fall through to the rest of main().

    # Under rootless podman, conmon places per-container console sockets
    # (`conmon-term.XXXXXX`) directly in `$TMPDIR`. Bazel's test driver sets
    # `TMPDIR=$TEST_TMPDIR`, which is a long path under the bazel execroot
    # (~150+ chars). The kernel's unix-domain `sun_path` limit is 108 bytes,
    # so the socket path silently truncates and `crun` then can't open it
    # ("OCI runtime attempted to invoke a command that was not found"). The
    # fix is to point `$TMPDIR` at a short, persistent-for-this-launcher dir.
    #
    # `--test_env=TMPDIR=...` doesn't help — bazel resets `TMPDIR=$TEST_TMPDIR`
    # after user `--test_env` overrides for hermeticity. The launcher is the
    # right place to do this.
    #
    # We deliberately leave `$HOME` alone: podman's image storage lives at
    # `$HOME/.local/share/containers/storage`, and redirecting it would
    # invalidate the kindest/node image cache on every test run.
    if runtime == "podman":
        _short_tmpdir_for_podman()

    env = _kind_env(runtime_env)
    if runtime == "podman":
        env["KIND_EXPERIMENTAL_PROVIDER"] = "podman"

    cluster_name   = _allocate_cluster_name()
    kubeconfig     = os.path.join(test_tmpdir, "kubeconfig")
    output_env     = os.path.join(test_tmpdir, f"{cluster_target_name}.env")

    _log(f"cluster name: {cluster_name}")
    _log(f"env file:     {output_env}")
    _log(f"runtime:      {runtime}")

    # Create cluster.
    _create_cluster(kind_bin, cluster_name, k8s_node_version, kind_config, env)

    # Register shutdown handler immediately after cluster exists.
    def _shutdown(signum, _frame):
        _log(f"received signal {signum}, shutting down…")
        _delete_cluster(kind_bin, cluster_name, env)
        sys.exit(0)

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT,  _shutdown)

    try:
        _get_kubeconfig(kind_bin, cluster_name, kubeconfig, env)
        _wait_apiserver_ready(kubectl_bin, kubeconfig)
        apiserver_url = _get_api_server_url(kubectl_bin, kubeconfig)
        _log(f"API server: {apiserver_url}")

        for tarball_short in m.get("image_tarballs", []):
            tarball_path = _find_runfile(tarball_short, workspace)
            _load_image(kind_bin, cluster_name, tarball_path, env)

        manifest_files = m.get("manifest_files", [])
        if manifest_files:
            _log("waiting for default ServiceAccount…")
            _wait_default_serviceaccount(kubectl_bin, kubeconfig)
            _log(f"applying {len(manifest_files)} manifest file(s)…")
            resolved = [_find_runfile(p, workspace) for p in manifest_files]
            _apply_manifests(kubectl_bin, kubeconfig, resolved)

        # Write env file atomically.
        tmp = output_env + ".tmp"
        with open(tmp, "w") as f:
            f.write(f"KUBECONFIG={kubeconfig}\n")
            f.write(f"KIND_CLUSTER_NAME={cluster_name}\n")
            f.write(f"KUBE_API_SERVER={apiserver_url}\n")
            f.write(f"KUBECTL={kubectl_bin}\n")
        os.replace(tmp, output_env)
        _log(f"cluster ready — env file written: {output_env}")

        while True:
            signal.pause()

    except Exception:
        _delete_cluster(kind_bin, cluster_name, env)
        raise


if __name__ == "__main__":
    main()
