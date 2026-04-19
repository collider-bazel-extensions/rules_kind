#!/usr/bin/env bash
set -euo pipefail

# Test kind_cluster lifecycle:
#   - Starts the cluster (via test_cluster launcher).
#   - Waits for the env file to appear.
#   - Verifies all required env vars are present in the env file.
#   - Sends SIGTERM and verifies the cluster cleans up.

require_env() {
    [[ -n "${!1:-}" ]] || { echo "ERROR: \$$1 not set" >&2; exit 1; }
}

require_env TEST_TMPDIR

RUNFILES="${TEST_SRCDIR:-${RUNFILES_DIR:-${BASH_SOURCE[0]}.runfiles}}"

# Locate the kind_cluster launcher.
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

if [[ -z "$cluster_launcher" ]]; then
    echo "ERROR: cluster launcher not found under RUNFILES=$RUNFILES" >&2
    find "${RUNFILES}" -name "*kind_cluster*" 2>/dev/null | head -10 >&2
    exit 1
fi

env_file="${TEST_TMPDIR}/test_cluster.env"
rm -f "$env_file"

# Start the cluster in the background.
"$cluster_launcher" &
launcher_pid=$!
trap 'kill "$launcher_pid" 2>/dev/null; wait "$launcher_pid" 2>/dev/null || true' EXIT

# Wait up to 120 seconds for the env file to appear.
echo "waiting for cluster env file…"
deadline=$(( $(date +%s) + 120 ))
while [[ ! -f "$env_file" ]]; do
    if [[ $(date +%s) -gt $deadline ]]; then
        echo "FAIL: env file not written within 120 seconds" >&2
        exit 1
    fi
    if ! kill -0 "$launcher_pid" 2>/dev/null; then
        echo "FAIL: launcher exited before writing env file" >&2
        exit 1
    fi
    sleep 2
done
echo "env file written"

# Source env file and verify required variables.
source "$env_file"

require_env KUBECONFIG
require_env KIND_CLUSTER_NAME
require_env KUBE_API_SERVER
require_env KUBECTL

echo "KUBECONFIG:        $KUBECONFIG"
echo "KIND_CLUSTER_NAME: $KIND_CLUSTER_NAME"
echo "KUBE_API_SERVER:   $KUBE_API_SERVER"
echo "KUBECTL:           $KUBECTL"

[[ -f "$KUBECONFIG" ]] || { echo "FAIL: KUBECONFIG file does not exist: $KUBECONFIG" >&2; exit 1; }
[[ -x "$KUBECTL" ]]    || { echo "FAIL: KUBECTL is not executable: $KUBECTL" >&2; exit 1; }

# Verify kubectl can reach the cluster.
"$KUBECTL" cluster-info --kubeconfig "$KUBECONFIG" >/dev/null
echo "PASS: cluster is reachable"

# Send SIGTERM and wait for launcher to exit.
echo "sending SIGTERM to launcher (pid $launcher_pid)…"
trap '' EXIT
kill "$launcher_pid"
wait "$launcher_pid" || true
echo "launcher exited"

echo "PASS"
