#!/usr/bin/env bash
set -euo pipefail

# Test that manifests declared in kind_cluster are applied before the env file
# is written. Verifies the ConfigMap from tests/manifests/test_configmap.yaml
# is present in the cluster.

require_env() {
    [[ -n "${!1:-}" ]] || { echo "ERROR: \$$1 not set" >&2; exit 1; }
}

require_env TEST_TMPDIR

RUNFILES="${TEST_SRCDIR:-${RUNFILES_DIR:-${BASH_SOURCE[0]}.runfiles}}"

# Locate the kind_cluster launcher (the one with manifests).
cluster_launcher=""
for candidate in \
    "${RUNFILES}/_main/tests/test_cluster_with_manifests_kind_cluster.sh" \
    "${RUNFILES}/rules_kind/tests/test_cluster_with_manifests_kind_cluster.sh"
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

env_file="${TEST_TMPDIR}/test_cluster_with_manifests.env"
rm -f "$env_file"

# Start cluster in background.
"$cluster_launcher" &
launcher_pid=$!
trap 'kill "$launcher_pid" 2>/dev/null; wait "$launcher_pid" 2>/dev/null || true' EXIT

# Wait for env file — manifests must be applied before this appears.
echo "waiting for cluster with manifests…"
deadline=$(( $(date +%s) + 120 ))
while [[ ! -f "$env_file" ]]; do
    [[ $(date +%s) -le $deadline ]] || { echo "FAIL: timeout" >&2; exit 1; }
    kill -0 "$launcher_pid" 2>/dev/null || { echo "FAIL: launcher exited" >&2; exit 1; }
    sleep 2
done
echo "env file written — manifests were applied before env file"

source "$env_file"
require_env KUBECONFIG
require_env KUBECTL

# Verify the ConfigMap from the manifest is present.
value=$("$KUBECTL" get configmap test-config \
    --namespace default \
    --kubeconfig "$KUBECONFIG" \
    -o jsonpath='{.data.key}' 2>/dev/null || echo "")

if [[ "$value" != "rules-kind-test-value" ]]; then
    echo "FAIL: ConfigMap 'test-config' not found or has wrong value: '$value'" >&2
    exit 1
fi
echo "PASS: ConfigMap 'test-config' present with correct data"

trap '' EXIT
kill "$launcher_pid"
wait "$launcher_pid" || true

echo "PASS"
