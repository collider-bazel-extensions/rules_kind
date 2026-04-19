#!/usr/bin/env bash
set -euo pipefail

# Test pod-to-pod communication inside a kind cluster.
#
# A busybox HTTP server pod is pre-deployed via the kind_cluster manifest.
# This test:
#   1. Waits for the cluster env file (cluster fully ready, manifest applied).
#   2. Waits for the hello-server pod to reach Running state.
#   3. Runs a short-lived client pod that fetches http://hello-server:8080/.
#   4. Reads the client pod logs and verifies the expected response.
#
# This verifies that:
#   - Pods are scheduled and reach Running.
#   - The cluster DNS resolves Service names.
#   - Pod-to-pod HTTP traffic flows correctly.

require_env() {
    [[ -n "${!1:-}" ]] || { echo "ERROR: \$$1 not set" >&2; exit 1; }
}

require_env TEST_TMPDIR

RUNFILES="${TEST_SRCDIR:-${RUNFILES_DIR:-${BASH_SOURCE[0]}.runfiles}}"

# Locate the cluster launcher (test_cluster_pod_to_pod).
cluster_launcher=""
for candidate in \
    "${RUNFILES}/_main/tests/test_cluster_pod_to_pod_kind_cluster.sh" \
    "${RUNFILES}/rules_kind/tests/test_cluster_pod_to_pod_kind_cluster.sh"
do
    if [[ -f "$candidate" ]]; then
        cluster_launcher="$candidate"
        break
    fi
done

if [[ -z "$cluster_launcher" ]]; then
    echo "ERROR: cluster launcher not found under RUNFILES=$RUNFILES" >&2
    find "${RUNFILES}" -name "*pod_to_pod*" 2>/dev/null | head -10 >&2
    exit 1
fi

env_file="${TEST_TMPDIR}/test_cluster_pod_to_pod.env"
rm -f "$env_file"

# Start cluster in background.
"$cluster_launcher" &
launcher_pid=$!
trap 'kill "$launcher_pid" 2>/dev/null; wait "$launcher_pid" 2>/dev/null || true' EXIT

# Wait for the cluster to be ready and the manifest applied.
echo "waiting for cluster…"
deadline=$(( $(date +%s) + 120 ))
while [[ ! -f "$env_file" ]]; do
    [[ $(date +%s) -le $deadline ]] || { echo "FAIL: cluster startup timeout" >&2; exit 1; }
    kill -0 "$launcher_pid" 2>/dev/null || { echo "FAIL: launcher exited" >&2; exit 1; }
    sleep 2
done
echo "cluster ready"

source "$env_file"
require_env KUBECONFIG
require_env KUBECTL

# 1. Wait for the hello-server pod to reach Running.
echo "waiting for hello-server pod to reach Running…"
server_deadline=$(( $(date +%s) + 60 ))
server_phase=""
while [[ "$server_phase" != "Running" ]]; do
    if [[ $(date +%s) -gt $server_deadline ]]; then
        echo "FAIL: hello-server pod did not reach Running within 60s" >&2
        "$KUBECTL" describe pod hello-server \
            --namespace default \
            --kubeconfig "$KUBECONFIG" >&2 || true
        exit 1
    fi
    server_phase=$("$KUBECTL" get pod hello-server \
        --namespace default \
        --kubeconfig "$KUBECONFIG" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
    sleep 2
done
echo "PASS: hello-server is Running"

# 2. Run a client pod that fetches from the hello-server Service.
#    The Service DNS name 'hello-server' resolves within the cluster.
echo "running client pod…"
"$KUBECTL" run hello-client \
    --image=busybox:stable \
    --restart=Never \
    --namespace default \
    --kubeconfig "$KUBECONFIG" \
    --overrides='{"spec":{"automountServiceAccountToken":false}}' \
    -- sh -c 'wget -qO- http://hello-server:8080/'

# 3. Wait for the client pod to complete.
echo "waiting for client pod to complete…"
client_deadline=$(( $(date +%s) + 60 ))
client_phase=""
while [[ "$client_phase" != "Succeeded" ]]; do
    if [[ $(date +%s) -gt $client_deadline ]]; then
        echo "FAIL: hello-client pod did not complete within 60s" >&2
        "$KUBECTL" describe pod hello-client \
            --namespace default \
            --kubeconfig "$KUBECONFIG" >&2 || true
        exit 1
    fi
    if [[ "$client_phase" == "Failed" ]]; then
        echo "FAIL: hello-client pod failed" >&2
        "$KUBECTL" logs hello-client \
            --namespace default \
            --kubeconfig "$KUBECONFIG" >&2 || true
        exit 1
    fi
    client_phase=$("$KUBECTL" get pod hello-client \
        --namespace default \
        --kubeconfig "$KUBECONFIG" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
    sleep 2
done
echo "PASS: hello-client pod completed"

# 4. Verify the response from the server.
response=$("$KUBECTL" logs hello-client \
    --namespace default \
    --kubeconfig "$KUBECONFIG")

echo "client received: $response"

if [[ "$response" != *"Hello from rules_kind"* ]]; then
    echo "FAIL: unexpected response: '$response'" >&2
    exit 1
fi
echo "PASS: client received expected response from server"

# Clean up.
"$KUBECTL" delete pod hello-client \
    --namespace default \
    --kubeconfig "$KUBECONFIG" \
    --ignore-not-found >/dev/null

trap '' EXIT
kill "$launcher_pid"
wait "$launcher_pid" || true

echo "PASS"
