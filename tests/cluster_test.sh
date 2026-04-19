#!/usr/bin/env bash
set -euo pipefail

# Test basic cluster connectivity and pod scheduling.

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
    exit 1
fi

env_file="${TEST_TMPDIR}/test_cluster.env"
rm -f "$env_file"

# Start cluster in background.
"$cluster_launcher" &
launcher_pid=$!
trap 'kill "$launcher_pid" 2>/dev/null; wait "$launcher_pid" 2>/dev/null || true' EXIT

# Wait for env file.
echo "waiting for cluster…"
deadline=$(( $(date +%s) + 120 ))
while [[ ! -f "$env_file" ]]; do
    [[ $(date +%s) -le $deadline ]] || { echo "FAIL: timeout" >&2; exit 1; }
    kill -0 "$launcher_pid" 2>/dev/null || { echo "FAIL: launcher exited" >&2; exit 1; }
    sleep 2
done

source "$env_file"
require_env KUBECONFIG
require_env KUBECTL

# 1. Verify nodes are ready.
echo "checking nodes…"
node_count=$("$KUBECTL" get nodes --kubeconfig "$KUBECONFIG" \
    -o jsonpath='{.items[*].metadata.name}' | wc -w)
[[ "$node_count" -ge 1 ]] || { echo "FAIL: no nodes found" >&2; exit 1; }
echo "PASS: $node_count node(s) found"

# 2. Run a simple pod and verify it reaches Running or Succeeded state.
# Wait for the default ServiceAccount to exist (created async after cluster start).
echo "waiting for default ServiceAccount…"
sa_deadline=$(( $(date +%s) + 30 ))
until "$KUBECTL" get serviceaccount default --kubeconfig "$KUBECONFIG" >/dev/null 2>&1; do
    [[ $(date +%s) -le $sa_deadline ]] || { echo "FAIL: default ServiceAccount not found" >&2; exit 1; }
    sleep 1
done

echo "scheduling test pod…"
"$KUBECTL" run kind-test-pod \
    --image=busybox:stable \
    --restart=Never \
    --kubeconfig "$KUBECONFIG" \
    -- sh -c 'echo hello'

# Wait up to 60 seconds for the pod to complete.
pod_deadline=$(( $(date +%s) + 60 ))
pod_phase=""
while [[ "$pod_phase" != "Running" && "$pod_phase" != "Succeeded" ]]; do
    if [[ $(date +%s) -gt $pod_deadline ]]; then
        echo "FAIL: kind-test-pod did not reach Running/Succeeded within 60s" >&2
        "$KUBECTL" describe pod kind-test-pod --kubeconfig "$KUBECONFIG" >&2 || true
        exit 1
    fi
    pod_phase=$("$KUBECTL" get pod kind-test-pod \
        --kubeconfig "$KUBECONFIG" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
    sleep 2
done
echo "PASS: kind-test-pod phase=$pod_phase"

# Clean up pod.
"$KUBECTL" delete pod kind-test-pod \
    --kubeconfig "$KUBECONFIG" --ignore-not-found >/dev/null

trap '' EXIT
kill "$launcher_pid"
wait "$launcher_pid" || true

echo "PASS"
