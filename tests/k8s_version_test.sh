#!/usr/bin/env bash
set -euo pipefail

# Boots a kind_cluster and checks the API server runs exactly the Kubernetes
# version rules_kind pins for that minor, and that the bundled kubectl is
# the same minor.
#
# Usage: k8s_version_test.sh <cluster target name> <expected server gitVersion>
#   e.g. k8s_version_test.sh test_cluster_1_37 v1.37.0

target="$1"
want_server="$2"
want_minor=$(sed -E 's/^v([0-9]+\.[0-9]+)\..*/\1/' <<< "$want_server")

[[ -n "${TEST_TMPDIR:-}" ]] || { echo "ERROR: \$TEST_TMPDIR not set" >&2; exit 1; }
RUNFILES="${TEST_SRCDIR:-${RUNFILES_DIR:-${BASH_SOURCE[0]}.runfiles}}"

launcher=""
for candidate in \
    "${RUNFILES}/_main/tests/${target}_kind_cluster.sh" \
    "${RUNFILES}/rules_kind/tests/${target}_kind_cluster.sh"
do
    [[ -f "$candidate" ]] && { launcher="$candidate"; break; }
done
[[ -n "$launcher" ]] || { echo "ERROR: launcher for $target not found" >&2; exit 1; }

env_file="${TEST_TMPDIR}/${target}.env"
rm -f "$env_file"
"$launcher" &
pid=$!
trap 'kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true' EXIT

deadline=$(( $(date +%s) + 240 ))
while [[ ! -f "$env_file" ]]; do
    [[ $(date +%s) -le $deadline ]] || { echo "FAIL: env file not written within 240 s" >&2; exit 1; }
    kill -0 "$pid" 2>/dev/null || { echo "FAIL: launcher exited before writing env file" >&2; exit 1; }
    sleep 2
done
source "$env_file"

json=$("$KUBECTL" version -o json --kubeconfig "$KUBECONFIG")
got_server=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])' <<< "$json")
got_client=$(python3 -c 'import json,sys; v=json.load(sys.stdin)["clientVersion"]; print(v["major"]+"."+v["minor"].rstrip("+"))' <<< "$json")
echo "server: $got_server  kubectl: $got_client"

[[ "$got_server" == "$want_server" ]] || { echo "FAIL: server is $got_server, want $want_server" >&2; exit 1; }
[[ "$got_client" == "$want_minor" ]] || { echo "FAIL: kubectl is $got_client, want $want_minor" >&2; exit 1; }

"$KUBECTL" wait --for=condition=Ready node --all --timeout=120s --kubeconfig "$KUBECONFIG"
echo "PASS: $target runs $got_server"
