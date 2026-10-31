#!/usr/bin/env bash
set -euo pipefail

# Test kind_cluster cleanup when the launcher is not shut down cleanly (#9):
#   - SIGKILL to the launcher: the reaper deletes the cluster.
#   - Parent exits without signalling (rules_itest on test failure): the
#     launcher notices and deletes the cluster.
#   - RULES_KIND_KEEP_CLUSTER=1: SIGTERM leaves the cluster running.

[[ -n "${TEST_TMPDIR:-}" ]] || { echo "ERROR: \$TEST_TMPDIR not set" >&2; exit 1; }

RUNFILES="${TEST_SRCDIR:-${RUNFILES_DIR:-${BASH_SOURCE[0]}.runfiles}}"

cluster_launcher=""
for candidate in \
    "${RUNFILES}/_main/tests/test_cluster_kind_cluster.sh" \
    "${RUNFILES}/rules_kind/tests/test_cluster_kind_cluster.sh"
do
    if [[ -f "$candidate" ]]; then
        cluster_launcher="$candidate"
        break
    fi
done
[[ -n "$cluster_launcher" ]] || { echo "ERROR: cluster launcher not found" >&2; exit 1; }

if docker info >/dev/null 2>&1; then
    runtime=docker
else
    runtime=podman
    # Same image store as the launcher (Bazel sets HOME=$TEST_TMPDIR).
    home=$(getent passwd "$(id -u)" | cut -d: -f6)
    export XDG_DATA_HOME="${XDG_DATA_HOME:-$home/.local/share}"
    export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$home/.config}"
fi

env_file="${TEST_TMPDIR}/test_cluster.env"

# Number of node containers kind created for cluster $1.
node_count() {
    "$runtime" ps -a -q --filter "label=io.x-k8s.kind.cluster=$1" | wc -l
}

# Wait for the env file; $1 is a pid that must stay alive meanwhile.
wait_env_file() {
    local deadline=$(( $(date +%s) + 180 ))
    while [[ ! -f "$env_file" ]]; do
        if [[ $(date +%s) -gt $deadline ]]; then
            echo "FAIL: env file not written within 180 seconds" >&2
            exit 1
        fi
        kill -0 "$1" 2>/dev/null || { echo "FAIL: launcher exited early" >&2; exit 1; }
        sleep 2
    done
}

# Wait until cluster $1 has no node containers left.
wait_deleted() {
    local deadline=$(( $(date +%s) + 120 ))
    while [[ $(node_count "$1") -ne 0 ]]; do
        if [[ $(date +%s) -gt $deadline ]]; then
            echo "FAIL: cluster $1 still present after 120 seconds" >&2
            cat "${TEST_TMPDIR}/test_cluster.reaper.log" >&2 || true
            exit 1
        fi
        sleep 2
    done
}

cluster_name() {
    sed -n 's/^KIND_CLUSTER_NAME=//p' "$env_file"
}

# --- 1. SIGKILL ------------------------------------------------------------
echo "=== SIGKILL to launcher"
rm -f "$env_file"
"$cluster_launcher" &
pid=$!
wait_env_file "$pid"
name=$(cluster_name)
[[ $(node_count "$name") -gt 0 ]] || { echo "FAIL: no nodes for $name" >&2; exit 1; }
# Bazel strips XDG_RUNTIME_DIR; systemctl --user needs it to find the bus.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if command -v systemctl >/dev/null && systemctl --user is-active default.target >/dev/null 2>&1; then
    systemctl --user is-active "rules-kind-reaper-$name.service" >/dev/null \
        || { echo "FAIL: reaper unit rules-kind-reaper-$name not active" >&2; exit 1; }
    echo "PASS: reaper runs as systemd user unit rules-kind-reaper-$name"
fi
kill -KILL "$pid"
wait "$pid" 2>/dev/null || true
wait_deleted "$name"
echo "PASS: $name deleted after SIGKILL"

# --- 2. Orphaned launcher --------------------------------------------------
echo "=== parent exits without signalling the launcher"
rm -f "$env_file"
pidfile="${TEST_TMPDIR}/launcher.pid"
bash -c '"$1" & echo $! > "$2"; wait' _ "$cluster_launcher" "$pidfile" &
parent=$!
wait_env_file "$parent"
name=$(cluster_name)
launcher_pid=$(cat "$pidfile")
kill -KILL "$parent"
wait "$parent" 2>/dev/null || true
wait_deleted "$name"
deadline=$(( $(date +%s) + 30 ))
while kill -0 "$launcher_pid" 2>/dev/null; do
    [[ $(date +%s) -le $deadline ]] || { echo "FAIL: orphaned launcher still running" >&2; exit 1; }
    sleep 1
done
echo "PASS: $name deleted and launcher exited after its parent died"

# --- 3. RULES_KIND_KEEP_CLUSTER ------------------------------------------------
echo "=== RULES_KIND_KEEP_CLUSTER=1"
rm -f "$env_file"
RULES_KIND_KEEP_CLUSTER=1 "$cluster_launcher" &
pid=$!
wait_env_file "$pid"
name=$(cluster_name)
kill -TERM "$pid"
wait "$pid" || true
sleep 5
if [[ $(node_count "$name") -eq 0 ]]; then
    echo "FAIL: cluster $name deleted despite RULES_KIND_KEEP_CLUSTER=1" >&2
    exit 1
fi
echo "PASS: $name kept"
# Clean up the kept cluster ourselves.
"$runtime" rm -f $("$runtime" ps -a -q --filter "label=io.x-k8s.kind.cluster=$name") >/dev/null

echo "PASS"
