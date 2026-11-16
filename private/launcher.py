#!/usr/bin/env python3
"""
rules_kind launcher.

Reads RULES_KIND_MANIFEST (JSON) and performs the full kind cluster lifecycle:
  detect runtime (Docker or podman) → kind create cluster
  → kind get kubeconfig → wait for API server
  → kind load image-archive (images) → kubectl apply (manifests)
  → write $TEST_TMPDIR/<name>.env → wait
  → SIGTERM / SIGINT / parent exit → kind delete cluster → exit 0

Cleanup:
  A reaper (this script with --reap-pid or --reap) is started before the
  cluster is created. If the launcher dies without finishing teardown
  (SIGKILL, crash, rules_itest's shutdown timeout), the reaper deletes the
  cluster. Bazel kills every process a test leaves behind when the test
  exits, so the reaper must not be one of the test's processes: when a
  systemd user manager is reachable it runs as a transient service
  (`systemd-run --user`) that watches the launcher's pid. Otherwise it falls
  back to a child in its own session holding a pipe from the launcher (EOF
  without "done" → delete), which only covers deaths while the test is still
  running. Set RULES_KIND_KEEP_CLUSTER=1 to leave the cluster running for
  debugging.

  A delete counts only once `kind get clusters` no longer lists the cluster
  and no container carries its label. The launcher releases the reaper only
  then; otherwise the reaper retries with backoff for up to 30 minutes. Each
  cluster has an ownership record and a log in $XDG_STATE_HOME/rules_kind
  (default ~/.local/state/rules_kind), and every launcher first deletes
  recorded clusters whose launcher and reaper are both gone.

Admission:
  At most RULES_KIND_MAX_CLUSTERS (default 2; 0 = no limit) launchers per user
  run a cluster at once: each holds a flock on a slot file under
  $XDG_RUNTIME_DIR/rules_kind/slots until it exits (the kernel drops the lock
  on SIGKILL too). RULES_KIND_SLOT_DIR shares the slots between users.
  Optionally RULES_KIND_MIN_FREE_MB waits for MemAvailable.

Container runtime:
  By default, Docker is used. If Docker is unavailable, podman is used
  automatically (KIND_EXPERIMENTAL_PROVIDER=podman). Rootless podman requires
  running under a systemd scope with Delegate=yes; the launcher handles this
  by re-executing itself via systemd-run when needed.
"""

import atexit
import dataclasses
import fcntl
import grp
import json
import os
import pwd
import re
import shlex
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

# Persistent per-cluster log (see _state_dir); set once the name is known.
_LOG_FILE = None


def _log(msg):
    line = f"[rules_kind] {msg}"
    if _LOG_FILE:
        try:
            with open(_LOG_FILE, "a") as f:
                f.write(time.strftime("%Y-%m-%dT%H:%M:%S ") + line + "\n")
        except OSError:
            pass
    try:
        print(line, flush=True)
    except (BrokenPipeError, OSError):
        # The reader is gone (rules_itest exited after a failed test). Keep
        # going: teardown must still reach `kind delete`.
        _detach_stdout()


def _detach_stdout():
    try:
        fd = os.open(os.devnull, os.O_WRONLY)
        os.dup2(fd, sys.stdout.fileno())
        os.close(fd)
    except (OSError, ValueError):
        pass


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

# `docker info` / `podman info` can take well over 5 s on a loaded host
# (several kind clusters starting at once on a CI runner); a short timeout
# misreports a busy runtime as a missing one.
_RUNTIME_PROBE_TIMEOUT_S = 30


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
            capture_output=True, text=True, timeout=_RUNTIME_PROBE_TIMEOUT_S,
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
        docker_problem = f"docker info timed out after {_RUNTIME_PROBE_TIMEOUT_S} s (daemon hung?)"

    # Fall back to podman.
    try:
        result = subprocess.run(
            ["podman", "--runtime", "/usr/bin/crun", "info"],
            capture_output=True, text=True, timeout=_RUNTIME_PROBE_TIMEOUT_S,
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
        podman_problem = f"podman info timed out after {_RUNTIME_PROBE_TIMEOUT_S} s"

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


def _real_home():
    """The passwd home; Bazel's test runner points $HOME at $TEST_TMPDIR."""
    try:
        return pwd.getpwuid(os.getuid()).pw_dir or None
    except KeyError:
        return None


def _use_real_home_for_containers():
    """Keep rootless podman's storage and config in the user's real home.

    Bazel's test runner sets `HOME=$TEST_TMPDIR`, and rootless podman keeps
    its image store under `$XDG_DATA_HOME` (default `$HOME/.local/share`).
    Left alone, every test run gets a fresh store under the execroot: the
    kindest/node image is pulled again each time, and the store's
    subuid-owned files make the next build fail ("Failed to prepare the
    symlink forest ... Operation not permitted"). Pointing the XDG dirs at
    the passwd home fixes both. kind and kubectl read `$HOME` (for
    `~/.kube/config`), not these, so they stay inside the test's tmpdir.
    """
    home = _real_home()
    if not home or os.environ.get("HOME") == home:
        return
    os.environ.setdefault("XDG_DATA_HOME", os.path.join(home, ".local", "share"))
    os.environ.setdefault("XDG_CONFIG_HOME", os.path.join(home, ".config"))


def _systemd_user_env():
    """Environment for `systemd-run --user`, which needs XDG_RUNTIME_DIR and
    DBUS_SESSION_BUS_ADDRESS. Bazel's sandbox may strip these; derive them
    from the real UID."""
    env = os.environ.copy()
    uid = os.getuid()
    xdg = f"/run/user/{uid}"
    if not env.get("XDG_RUNTIME_DIR") and os.path.isdir(xdg):
        env["XDG_RUNTIME_DIR"] = xdg
    if not env.get("DBUS_SESSION_BUS_ADDRESS"):
        bus = f"unix:path={xdg}/bus"
        if os.path.exists(f"{xdg}/bus"):
            env["DBUS_SESSION_BUS_ADDRESS"] = bus
    return env


def _reexec_under_systemd():
    """Re-exec this process under systemd-run --scope --property=Delegate=yes."""
    _log("re-executing under systemd-run for rootless podman cgroup delegation…")

    env = _systemd_user_env()

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


# kind's podman provider checks for its `kind` network and then creates it,
# so two clusters created at once can both find it missing; the second
# `podman network create` fails and so does that `kind create cluster`. kind
# fails at that step before it creates any node, and on a retry it finds the
# network and uses it. (kind's docker provider handles the same race itself.)
_NETWORK_RACE = "network already exists"
_CREATE_ATTEMPTS = 3


def _create_cluster(kind_bin, cluster_name, node_image, kind_config, env):
    cmd = [
        kind_bin, "create", "cluster",
        "--name", cluster_name,
        "--image", node_image,
    ]
    if kind_config:
        cmd += ["--config", kind_config]
    _log(f"creating cluster {cluster_name} ({node_image})…")
    for attempt in range(1, _CREATE_ATTEMPTS + 1):
        result = _run(cmd, env=env, check=False)
        if result.returncode == 0:
            break
        if attempt < _CREATE_ATTEMPTS and _NETWORK_RACE in result.stdout + result.stderr:
            _log("another cluster created the kind network at the same time; retrying")
            time.sleep(attempt)
            continue
        raise RuntimeError(
            f"command failed: {' '.join(str(a) for a in cmd)}\n"
            f"stdout: {result.stdout}\n"
            f"stderr: {result.stderr}"
        )
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


def _keep_cluster():
    """True when RULES_KIND_KEEP_CLUSTER asks to leave the cluster running."""
    return os.environ.get("RULES_KIND_KEEP_CLUSTER", "").lower() not in (
        "", "0", "false", "no")


def _proc_start_time(pid):
    """Start time of `pid` in clock ticks since boot (field 22 of
    /proc/<pid>/stat), or None if the process is gone. Paired with the pid
    it identifies a process even if the pid is reused."""
    try:
        with open(f"/proc/{pid}/stat") as f:
            stat = f.read()
    except OSError:
        return None
    # Field 2 (comm) may contain spaces; fields after it follow the last ")".
    return stat[stat.rindex(")") + 2:].split()[19]


_ENV_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def _reaper_unit_name(cluster_name):
    return f"rules-kind-reaper-{cluster_name}"


def _setenv_flags(env):
    # A service starts with the user manager's environment, not ours; pass
    # ours through (`-E NAME` copies NAME from systemd-run's environment).
    # systemd rejects names that aren't shell identifiers (e.g. bash's
    # exported `BASH_FUNC_f%%`).
    return [f"--setenv={k}" for k in sorted(env) if _ENV_NAME.fullmatch(k)]


def _runtime_socket(env):
    """(path, gid) of the Docker daemon's unix socket, or (None, None). A
    rootless podman socket belongs to the user, so it can't hit #17."""
    if _runtime_cli(env) != "docker":
        return None, None
    host = env.get("DOCKER_HOST", "")
    if host and not host.startswith("unix://"):
        return None, None
    path = host[len("unix://"):] if host else "/var/run/docker.sock"
    try:
        return path, os.stat(path).st_gid
    except OSError:
        return path, None


_PROBE_MARK = "rules-kind-probe-status:"


def _unit_reaches_runtime(env, prefix=()):
    """Whether a systemd user unit, started like the reaper (optionally
    through `prefix`, e.g. `sg docker -c`), can talk to the container
    runtime. The unit gets the user manager's credentials, not ours (#17).

    Returns (True|False|None, detail). None: the probe itself couldn't run
    (e.g. a systemd without --pipe), so nothing is known."""
    # The status line tells "the runtime refused" from "the probe didn't run".
    probe = (f'out=$({_runtime_cli(env)} info 2>&1 >/dev/null); s=$?; '
             f'printf "%s\\n" "$out" >&2; echo {_PROBE_MARK}$s')
    inner = ["sh", "-c", probe]
    if prefix:
        inner = list(prefix) + [shlex.join(inner)]
    cmd = (["systemd-run", "--user", "--wait", "--pipe", "--quiet", "--collect"]
           + _setenv_flags(env) + ["--"] + inner)
    sd_env = _systemd_user_env()
    sd_env.update(env)
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, env=sd_env,
                           stdin=subprocess.DEVNULL,
                           timeout=_RUNTIME_PROBE_TIMEOUT_S + 30)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, str(e)
    m = re.search(_PROBE_MARK + r"(\d+)", r.stdout)
    detail = " ".join((r.stderr or "").split())[:300]
    if not m:
        return None, detail or f"systemd-run exited {r.returncode}"
    return m.group(1) == "0", detail


def _reaper_prefix(env):
    """How to start the reaper unit so it reaches the runtime: [] (as is),
    ["sg", <group>, "-c"], or None (it can't: use a child process)."""
    ok, detail = _unit_reaches_runtime(env)
    if ok or ok is None:
        if ok is None:
            _log(f"reaper: couldn't probe the user unit's runtime access ({detail}); "
                 "assuming it has it")
        return []
    path, gid = _runtime_socket(env)
    group = None
    if gid is not None and (gid in os.getgroups() or gid == os.getegid()):
        try:
            group = grp.getgrgid(gid).gr_name
        except KeyError:
            group = None
    if group and shutil.which("sg"):
        # The user is in the socket's group but the user manager, started
        # before they joined, isn't. sg (setuid newgrp) grants a group the
        # group database lists them in, with no password and no re-login.
        prefix = ["sg", group, "-c"]
        ok2, detail2 = _unit_reaches_runtime(env, prefix)
        if ok2:
            _log(f"reaper: the systemd user manager isn't in group {group} ({path}'s "
                 f"group; it started before you joined it), so the reaper unit runs "
                 f"under `sg {group}`")
            return prefix
        detail = f"{detail}; through `sg {group}`: {detail2}"
    if group:
        advice = (f" Log out and back in (or restart user@{os.getuid()}.service) so "
                  f"the user manager picks up group {group}.")
    elif gid is not None:
        advice = (f" This process isn't in {path}'s group (gid {gid}) either; "
                  "the runtime may be reachable some other way.")
    else:
        advice = ""
    _log("reaper: a systemd user unit can't reach the container runtime "
         f"({detail}); using a child process instead. A test that is killed can "
         "then leave its cluster until the next launcher's sweep." + advice)
    return None


def _start_reaper_unit(kind_bin, cluster_name, env, log_path):
    """Start the reaper as a transient systemd user service. systemd, not
    the test, is its parent, so Bazel can't kill it when the test exits.
    Returns the unit name, or None if no user manager is reachable or a
    unit couldn't reach the container runtime (#17)."""
    if not shutil.which("systemd-run") or not os.path.exists("/proc/self/stat"):
        return None
    prefix = _reaper_prefix(env)
    if prefix is None:
        return None
    unit = _reaper_unit_name(cluster_name)
    pid = os.getpid()
    cmd = ["systemd-run", "--user", "--quiet", "--collect", "--unit", unit,
           "--property=Delegate=yes"]
    cmd += _setenv_flags(env)
    reap = [sys.executable, os.path.abspath(__file__), "--reap-pid",
            kind_bin, cluster_name, str(pid), _proc_start_time(pid), log_path]
    cmd += ["--"] + (list(prefix) + [shlex.join(reap)] if prefix else reap)
    sd_env = _systemd_user_env()
    sd_env.update(env)
    try:
        result = subprocess.run(cmd, capture_output=True, text=True,
                                env=sd_env, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as e:
        _log(f"reaper: systemd-run unavailable ({e}); using a child process")
        return None
    if result.returncode != 0:
        _log("reaper: systemd-run --user failed "
             f"({result.stderr.strip()[:200]}); using a child process")
        return None
    _log(f"reaper: systemd user unit {unit}")
    _write_record(cluster_name, reaper_unit=unit)
    return unit


def _start_reaper(kind_bin, cluster_name, env, log_path):
    """Start the reaper. Prefer a systemd user unit (see _start_reaper_unit);
    fall back to a child in its own session so process-group signals sent
    to the launcher (rules_itest SIGKILLs the whole group after its shutdown
    timeout) don't reach it. Returns the unit name or the Popen; a Popen's
    stdin stays open until teardown is done."""
    unit = _start_reaper_unit(kind_bin, cluster_name, env, log_path)
    if unit:
        return unit
    log = open(log_path, "ab")
    try:
        proc = subprocess.Popen(
            [sys.executable, os.path.abspath(__file__),
             "--reap", kind_bin, cluster_name],
            stdin=subprocess.PIPE, stdout=log, stderr=log,
            env=env, start_new_session=True,
        )
    finally:
        log.close()
    _write_record(cluster_name, reaper_pid=proc.pid,
                  reaper_start_time=_proc_start_time(proc.pid))
    return proc


def _release_reaper(reaper):
    """Tell the reaper the cluster is gone, so it exits without deleting.
    Only called after _delete_cluster confirmed the deletion."""
    if reaper is None:
        return
    if isinstance(reaper, str):
        subprocess.run(["systemctl", "--user", "stop", "--no-block", reaper],
                       capture_output=True, env=_systemd_user_env())
        return
    try:
        reaper.stdin.write(b"done")
        reaper.stdin.close()
    except OSError:
        pass


def _reap_main(kind_bin, cluster_name):
    """Reaper mode: block until the launcher closes our stdin, then delete
    the cluster unless the launcher reported that it already did."""
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    if sys.stdin.buffer.read() == b"done":
        return
    _log(f"launcher exited without confirming {cluster_name} is deleted")
    _reap_delete(kind_bin, cluster_name)


def _reap_pid_main(kind_bin, cluster_name, pid, start_time, log_path):
    """Reaper mode under systemd: poll the launcher (pid + start time) and
    delete the cluster once it is gone, retrying until it is. The launcher
    stops this unit once it has confirmed the deletion itself."""
    fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    os.dup2(fd, 1)
    os.dup2(fd, 2)
    os.close(fd)
    while _proc_start_time(pid) == start_time:
        time.sleep(1)
    _log(f"launcher {pid} exited; deleting {cluster_name} if it still exists")
    _reap_delete(kind_bin, cluster_name)


def _reap_delete(kind_bin, cluster_name):
    # The launcher removes its short podman TMPDIR on exit; kind still needs one.
    tmpdir = os.environ.get("TMPDIR")
    if tmpdir:
        os.makedirs(tmpdir, exist_ok=True)
    _delete_until_gone(kind_bin, cluster_name, os.environ.copy())
    if tmpdir and os.path.basename(tmpdir).startswith("rules_kind-tmp-"):
        _best_effort_rmtree(tmpdir)


# A single `kind delete` on a loaded host can take minutes.
_DELETE_TIMEOUT_S = 600
# How long the reaper keeps retrying a delete that does not stick.
_REAPER_DEADLINE_S = 30 * 60


def _runtime_cli(env):
    return "podman" if env.get("KIND_EXPERIMENTAL_PROVIDER") == "podman" else "docker"


def _cluster_gone(kind_bin, cluster_name, env):
    """True once kind no longer lists the cluster and no container carries
    its label. A killed or failed delete can leave stopped nodes behind
    (`Exited (137)`) that kind still lists."""
    try:
        r = subprocess.run([kind_bin, "get", "clusters"], capture_output=True,
                           text=True, env=env, timeout=120)
        if r.returncode != 0 or cluster_name in r.stdout.split():
            return False
        r = subprocess.run(
            [_runtime_cli(env), "ps", "-a", "-q", "--filter",
             f"label=io.x-k8s.kind.cluster={cluster_name}"],
            capture_output=True, text=True, env=env, timeout=120)
        return r.returncode == 0 and not r.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return False


def _denied(text):
    return "permission denied" in text.lower()


def _delete_attempt(kind_bin, cluster_name, env):
    """One `kind delete`, then check: "gone", "present" or "denied" (this
    process can't reach the container runtime)."""
    _log(f"deleting cluster {cluster_name}…")
    failure = ""
    try:
        _run([kind_bin, "delete", "cluster", "--name", cluster_name], env=env,
             timeout=_DELETE_TIMEOUT_S)
    except Exception as e:
        failure = str(e)
        if not _denied(failure):
            _log(f"warning: kind delete failed: {e}")
    if _cluster_gone(kind_bin, cluster_name, env):
        _log("cluster deleted")
        _forget_cluster(cluster_name)
        return "gone"
    if _denied(failure):
        path, gid = _runtime_socket(env)
        try:
            group = grp.getgrgid(gid).gr_name if gid is not None else None
        except KeyError:
            group = None
        mine = " ".join(str(g) for g in os.getgroups())
        _log("error: the reaper cannot reach the container runtime: permission denied"
             + (f" on {path}" if path else "")
             + (f" (group {group}; this process has groups {mine})" if group else "")
             + f". {cluster_name} was not deleted.")
        return "denied"
    _log(f"warning: cluster {cluster_name} is still present after kind delete")
    return "present"


def _delete_cluster(kind_bin, cluster_name, env):
    """One `kind delete`, then check. Returns True if the cluster is gone."""
    return _delete_attempt(kind_bin, cluster_name, env) == "gone"


# Retrying "permission denied" for half an hour helps no one: credentials
# don't change under a running process, and while the reaper lives the
# next launcher's sweep (which runs with the test's groups) skips the
# cluster.
_DENIED_ATTEMPTS = 3


def _delete_until_gone(kind_bin, cluster_name, env, deadline_s=_REAPER_DEADLINE_S):
    """Retry _delete_cluster with backoff (5 s doubling to 60 s)."""
    end = time.monotonic() + deadline_s
    delay = 5
    denied = 0
    while True:
        outcome = _delete_attempt(kind_bin, cluster_name, env)
        if outcome == "gone":
            break
        denied = denied + 1 if outcome == "denied" else 0
        if denied >= _DENIED_ATTEMPTS:
            _log(f"giving up on {cluster_name} after {denied} permission errors; "
                 "the next launcher's sweep, which runs with the test's groups, "
                 "deletes it")
            return False
        if time.monotonic() + delay > end:
            _log(f"giving up on {cluster_name} after {deadline_s} s; the next "
                 "launcher's sweep retries it")
            return False
        _log(f"retrying in {delay} s")
        time.sleep(delay)
        delay = min(delay * 2, 60)
    return True


# ---------------------------------------------------------------------------
# Ownership records, logs and the stale-cluster sweep
# ---------------------------------------------------------------------------

def _state_dir():
    """$XDG_STATE_HOME/rules_kind (default ~/.local/state/rules_kind, from
    the passwd home): logs and records that outlive $TEST_TMPDIR."""
    base = os.environ.get("XDG_STATE_HOME")
    if not base:
        home = _real_home() or tempfile.gettempdir()
        base = os.path.join(home, ".local", "state")
    d = os.path.join(base, "rules_kind")
    os.makedirs(d, exist_ok=True)
    return d


def _boot_id():
    try:
        with open("/proc/sys/kernel/random/boot_id") as f:
            return f.read().strip()
    except OSError:
        return ""


def _record_path(cluster_name):
    return os.path.join(_state_dir(), cluster_name + ".json")


def _write_record(cluster_name, **fields):
    """Create or update the ownership record of a cluster."""
    path = _record_path(cluster_name)
    rec = {}
    try:
        with open(path) as f:
            rec = json.load(f)
    except (OSError, ValueError):
        pass
    rec.update(fields, cluster=cluster_name)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(rec, f)
    os.replace(tmp, path)


def _forget_cluster(cluster_name):
    try:
        os.remove(_record_path(cluster_name))
    except OSError:
        pass


def _alive(boot_id, pid, start_time):
    """True if the process (pid + start time, this boot) still runs."""
    return (bool(boot_id) and boot_id == _boot_id() and pid is not None
            and _proc_start_time(pid) == start_time)


def _reaper_alive(rec):
    unit = rec.get("reaper_unit")
    if unit:
        r = subprocess.run(["systemctl", "--user", "is-active", "--quiet", unit],
                           capture_output=True, env=_systemd_user_env())
        if r.returncode == 0:
            return True
    return _alive(rec.get("boot_id"), rec.get("reaper_pid"),
                  rec.get("reaper_start_time"))


_LOG_RETENTION_S = 7 * 24 * 3600


def _sweep_stale_clusters(kind_bin, env, runtime):
    """Delete recorded clusters whose launcher and reaper are both gone, and
    prune old logs. Only this user's records are considered; clusters kept
    with RULES_KIND_KEEP_CLUSTER have none."""
    try:
        d = _state_dir()
        names = os.listdir(d)
    except OSError:
        return
    for n in sorted(names):
        path = os.path.join(d, n)
        if n.endswith(".log") and not os.path.exists(path[:-4] + ".json"):
            try:
                if time.time() - os.path.getmtime(path) > _LOG_RETENTION_S:
                    os.remove(path)
            except OSError:
                pass
            continue
        if not n.endswith(".json"):
            continue
        try:
            with open(path) as f:
                rec = json.load(f)
            name = rec["cluster"]
        except (OSError, ValueError, KeyError):
            continue
        if rec.get("runtime", runtime) != runtime:
            continue
        if _alive(rec.get("boot_id"), rec.get("pid"), rec.get("start_time")):
            continue
        if _reaper_alive(rec):
            continue
        # Another launcher may be sweeping the same record.
        try:
            fd = os.open(path, os.O_RDONLY)
        except OSError:
            continue
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(fd)
            continue
        try:
            _log(f"sweep: {name} was left by launcher pid {rec.get('pid')}, "
                 "which is gone; deleting it")
            _delete_cluster(kind_bin, name, env)
        finally:
            os.close(fd)


# ---------------------------------------------------------------------------
# Admission: a per-user limit on concurrent clusters
# ---------------------------------------------------------------------------

_DEFAULT_MAX_CLUSTERS = 2


def _env_int(name, default):
    raw = os.environ.get(name, "")
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        _log(f"warning: ignoring {name}={raw!r} (not an integer)")
        return default


def _slot_dir():
    """RULES_KIND_SLOT_DIR, or $XDG_RUNTIME_DIR/rules_kind/slots (per user).
    Point several users at one directory (e.g. a mode-1777 /var/tmp dir) to
    share the limit across them."""
    d = os.environ.get("RULES_KIND_SLOT_DIR")
    if d:
        os.makedirs(d, exist_ok=True)
        return d
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    if not os.path.isdir(runtime_dir):
        runtime_dir = os.path.join(tempfile.gettempdir(), f"rules_kind-{os.getuid()}")
    d = os.path.join(runtime_dir, "rules_kind", "slots")
    os.makedirs(d, mode=0o700, exist_ok=True)
    return d


def _acquire_slot(cluster_name, target):
    """Block until one of RULES_KIND_MAX_CLUSTERS slots is free and return
    its fd (kept open, i.e. locked, until the launcher exits), or None when
    there is no limit. The wait has no timeout of its own; the test's
    timeout bounds it."""
    limit = _env_int("RULES_KIND_MAX_CLUSTERS", _DEFAULT_MAX_CLUSTERS)
    if limit <= 0:
        return None
    d = _slot_dir()
    last_report = None
    while True:
        holders = []
        for i in range(limit):
            path = os.path.join(d, f"slot-{i}")
            fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o666)
            try:
                # Lockable by every user sharing RULES_KIND_SLOT_DIR (the
                # default directory is private to the user anyway).
                os.fchmod(fd, 0o666)
            except OSError:
                pass  # created by another user
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                try:
                    holders.append(os.read(fd, 4096).decode(errors="replace").strip())
                except OSError:
                    pass
                os.close(fd)
                continue
            os.ftruncate(fd, 0)
            os.write(fd, f"{cluster_name} pid {os.getpid()} target {target} "
                         f"since {time.strftime('%H:%M:%S')}".encode())
            _log(f"cluster slot {i + 1}/{limit} acquired")
            return fd
        now = time.monotonic()
        if last_report is None or now - last_report >= 60:
            _log(f"waiting for a cluster slot (RULES_KIND_MAX_CLUSTERS={limit}); "
                 "held by: " + "; ".join(h or "?" for h in holders))
            last_report = now
        time.sleep(2)


def _mem_available_mb():
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemAvailable:"):
                    return int(line.split()[1]) // 1024
    except (OSError, ValueError):
        pass
    return None


def _wait_free_memory():
    """With RULES_KIND_MIN_FREE_MB set, wait until MemAvailable reaches it."""
    want = _env_int("RULES_KIND_MIN_FREE_MB", 0)
    if want <= 0:
        return
    last_report = None
    while True:
        have = _mem_available_mb()
        if have is None or have >= want:
            return
        now = time.monotonic()
        if last_report is None or now - last_report >= 60:
            _log(f"waiting for memory: {have} MB available, "
                 f"RULES_KIND_MIN_FREE_MB={want}")
            last_report = now
        time.sleep(5)


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

    node_image = m["node_image"]

    kind_config = None
    if "kind_config" in m:
        kind_config = _find_runfile(m["kind_config"], workspace)

    _use_real_home_for_containers()

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
    # podman's image store is kept out of `$TEST_TMPDIR` by
    # _use_real_home_for_containers() above.
    if runtime == "podman":
        _short_tmpdir_for_podman()

    env = _kind_env(runtime_env)
    if runtime == "podman":
        env["KIND_EXPERIMENTAL_PROVIDER"] = "podman"

    cluster_name   = _allocate_cluster_name()
    kubeconfig     = os.path.join(test_tmpdir, "kubeconfig")
    output_env     = os.path.join(test_tmpdir, f"{cluster_target_name}.env")
    keep           = _keep_cluster()

    global _LOG_FILE
    log_path = os.path.join(_state_dir(), f"{cluster_name}.log")
    _LOG_FILE = log_path

    _log(f"cluster name: {cluster_name}")
    _log(f"env file:     {output_env}")
    _log(f"runtime:      {runtime}")
    _log(f"log:          {log_path}")

    _sweep_stale_clusters(kind_bin, env, runtime)
    slot = _acquire_slot(cluster_name, cluster_target_name)  # noqa: F841 (held until exit)
    _wait_free_memory()

    # rules_itest exits without signalling its services when the test fails,
    # leaving us orphaned. Watch for that by checking our parent pid.
    parent_pid = os.getppid()

    reaper = None
    if keep:
        _log("RULES_KIND_KEEP_CLUSTER is set: the cluster will not be deleted")
    else:
        pid = os.getpid()
        _write_record(cluster_name, boot_id=_boot_id(), pid=pid,
                      start_time=_proc_start_time(pid), runtime=runtime,
                      target=cluster_target_name, test_tmpdir=test_tmpdir)
        reaper = _start_reaper(kind_bin, cluster_name, env, log_path)

    def _teardown():
        if keep:
            _log(f"keeping cluster {cluster_name}; delete it with: "
                 f"kind delete cluster --name {cluster_name}")
        elif _delete_cluster(kind_bin, cluster_name, env):
            _release_reaper(reaper)
            # A clean teardown needs no log beyond the test's own output.
            global _LOG_FILE
            _LOG_FILE = None
            try:
                os.remove(log_path)
            except OSError:
                pass
        else:
            # Not released: the reaper retries once this launcher is gone.
            _log("leaving the cluster to the reaper")

    def _shutdown(signum, _frame):
        _log(f"received signal {signum}, shutting down…")
        _teardown()
        sys.exit(0)

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT,  _shutdown)

    try:
        _create_cluster(kind_bin, cluster_name, node_image, kind_config, env)
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

        while os.getppid() == parent_pid:
            time.sleep(1)
        _log("parent process exited without stopping the cluster service")
        _teardown()

    except Exception:
        _teardown()
        raise


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--reap":
        _reap_main(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 7 and sys.argv[1] == "--reap-pid":
        _reap_pid_main(sys.argv[2], sys.argv[3], int(sys.argv[4]),
                       sys.argv[5], sys.argv[6])
    elif len(sys.argv) == 3 and sys.argv[1] == "--sweep":
        # Delete this user's recorded clusters whose launcher and reaper are
        # gone: `python3 launcher.py --sweep <kind binary>`.
        _use_real_home_for_containers()
        _rt, _rt_env = _detect_runtime()
        _sweep_stale_clusters(sys.argv[2], _kind_env(_rt_env), _rt)
    else:
        main()
