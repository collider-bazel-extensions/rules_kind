#!/usr/bin/env python3
"""
rules_kind launcher.

Reads RULES_KIND_MANIFEST (JSON) and performs the full kind cluster lifecycle:
  kind create cluster → kind get kubeconfig → wait for API server
  → kind load image-archive (images) → kubectl apply (manifests)
  → write $TEST_TMPDIR/<name>.env → signal.pause()
  → SIGTERM → kind delete cluster → exit 0
"""

import dataclasses
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
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


# ---------------------------------------------------------------------------
# kind cluster lifecycle
# ---------------------------------------------------------------------------

def _allocate_cluster_name():
    return "kind-" + uuid.uuid4().hex[:12]


def _run(args, check=True, **kwargs):
    """Run a subprocess, print output on failure."""
    result = subprocess.run(args, capture_output=True, text=True, **kwargs)
    if check and result.returncode != 0:
        raise RuntimeError(
            f"command failed: {' '.join(str(a) for a in args)}\n"
            f"stdout: {result.stdout}\n"
            f"stderr: {result.stderr}"
        )
    return result


def _create_cluster(kind_bin, cluster_name, k8s_version, kind_config):
    """Run kind create cluster."""
    cmd = [
        kind_bin, "create", "cluster",
        "--name", cluster_name,
        "--image", f"kindest/node:v{k8s_version}",
    ]
    if kind_config:
        cmd += ["--config", kind_config]
    _log(f"creating cluster {cluster_name} (k8s v{k8s_version})…")
    _run(cmd)
    _log(f"cluster {cluster_name} created")


def _get_kubeconfig(kind_bin, cluster_name, kubeconfig_path):
    """Write kubeconfig for the cluster."""
    result = _run([kind_bin, "get", "kubeconfig", "--name", cluster_name])
    with open(kubeconfig_path, "w") as f:
        f.write(result.stdout)
    _log(f"kubeconfig written to {kubeconfig_path}")


def _wait_apiserver_ready(kubectl_bin, kubeconfig, timeout=120):
    """Poll kubectl cluster-info until the API server responds."""
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
    """Return the cluster API server URL from kubectl cluster-info."""
    result = _run([
        kubectl_bin, "config", "view",
        "--kubeconfig", kubeconfig,
        "--minify",
        "-o", "jsonpath={.clusters[0].cluster.server}",
    ])
    return result.stdout.strip()


def _load_image(kind_bin, cluster_name, tarball_path):
    """Load a Docker image tarball into the kind cluster."""
    _log(f"loading image: {os.path.basename(tarball_path)}")
    _run([
        kind_bin, "load", "image-archive",
        tarball_path,
        "--name", cluster_name,
    ])


def _apply_manifests(kubectl_bin, kubeconfig, manifest_files):
    """Apply YAML manifests in order."""
    for path in manifest_files:
        _log(f"applying: {os.path.basename(path)}")
        result = _run([
            kubectl_bin, "apply", "-f", path,
            "--kubeconfig", kubeconfig,
        ])
        if result.stdout.strip():
            _log(result.stdout.strip())


def _delete_cluster(kind_bin, cluster_name):
    """Delete the kind cluster (best-effort; called on shutdown)."""
    _log(f"deleting cluster {cluster_name}…")
    try:
        _run([kind_bin, "delete", "cluster", "--name", cluster_name])
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

    k8s_version = m.get("k8s_version", "1.29")

    # Resolve optional kind config.
    kind_config = None
    if "kind_config" in m:
        kind_config = _find_runfile(m["kind_config"], workspace)

    cluster_name   = _allocate_cluster_name()
    kubeconfig     = os.path.join(test_tmpdir, "kubeconfig")
    output_env     = os.path.join(test_tmpdir, f"{cluster_target_name}.env")

    _log(f"cluster name: {cluster_name}")
    _log(f"env file:     {output_env}")

    # Create cluster.
    _create_cluster(kind_bin, cluster_name, k8s_version, kind_config)

    # Register cleanup handler immediately after cluster exists.
    cluster_created = True

    def _shutdown(signum, _frame):
        _log(f"received signal {signum}, shutting down…")
        _delete_cluster(kind_bin, cluster_name)
        sys.exit(0)

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT,  _shutdown)

    try:
        # Write kubeconfig.
        _get_kubeconfig(kind_bin, cluster_name, kubeconfig)

        # Wait for API server.
        _wait_apiserver_ready(kubectl_bin, kubeconfig)

        # Get API server URL.
        apiserver_url = _get_api_server_url(kubectl_bin, kubeconfig)
        _log(f"API server: {apiserver_url}")

        # Load image tarballs.
        for tarball_short in m.get("image_tarballs", []):
            tarball_path = _find_runfile(tarball_short, workspace)
            _load_image(kind_bin, cluster_name, tarball_path)

        # Apply manifests.
        manifest_files = m.get("manifest_files", [])
        if manifest_files:
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

        # Block until signalled.
        while True:
            signal.pause()

    except Exception:
        # Clean up the cluster before propagating the exception.
        _delete_cluster(kind_bin, cluster_name)
        raise


if __name__ == "__main__":
    main()
