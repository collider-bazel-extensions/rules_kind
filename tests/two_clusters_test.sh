#!/usr/bin/env bash
set -euo pipefail

# Two kind_cluster targets in one test (#25):
#   - each env file's KUBECONFIG is $TEST_TMPDIR/<name>.kubeconfig, and the
#     two differ;
#   - each kubeconfig reaches its own cluster: its server is the env file's
#     KUBE_API_SERVER, and a namespace created through one is not seen
#     through the other;
#   - a third cluster with the same target name as one of them (from another
#     package) fails at once, naming both, and leaves the first's files alone.

[[ -n "${TEST_TMPDIR:-}" ]] || { echo "ERROR: \$TEST_TMPDIR not set" >&2; exit 1; }
RUNFILES="${TEST_SRCDIR:-${RUNFILES_DIR:-${BASH_SOURCE[0]}.runfiles}}"

launcher() { # <package/name> -> the kind_cluster wrapper
    local c
    for c in "${RUNFILES}/_main/$1_kind_cluster.sh" "${RUNFILES}/rules_kind/$1_kind_cluster.sh"; do
        [[ -f "$c" ]] && { echo "$c"; return; }
    done
    echo "ERROR: $1_kind_cluster.sh not found under $RUNFILES" >&2; exit 1
}
a_bin=$(launcher tests/two_a) && b_bin=$(launcher tests/two_b) && clash_bin=$(launcher tests/clash/two_a) || exit 1

pids=()
cleanup() {
    for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
    for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
}
trap cleanup EXIT

"$a_bin" > "$TEST_TMPDIR/two_a.log" 2>&1 & pids+=($!)
"$b_bin" > "$TEST_TMPDIR/two_b.log" 2>&1 & pids+=($!)

echo "waiting for both clusters…"
# Up to 900 s: includes waiting for cluster slots (RULES_KIND_MAX_CLUSTERS).
deadline=$(( $(date +%s) + 900 ))
for n in two_a two_b; do
    while [[ ! -f "$TEST_TMPDIR/$n.env" ]]; do
        if [[ $(date +%s) -gt $deadline ]] || ! kill -0 "${pids[0]}" 2>/dev/null || ! kill -0 "${pids[1]}" 2>/dev/null; then
            tail -n 20 "$TEST_TMPDIR/two_a.log" "$TEST_TMPDIR/two_b.log" >&2
            echo "FAIL: $n's env file not written" >&2; exit 1
        fi
        sleep 2
    done
done

envvar() { (set -a; source "$TEST_TMPDIR/$1.env"; printenv "$2"); }
ka=$(envvar two_a KUBECONFIG); kb=$(envvar two_b KUBECONFIG)
KUBECTL=$(envvar two_a KUBECTL)
echo "two_a: KUBECONFIG=$ka"; echo "two_b: KUBECONFIG=$kb"

[[ "$ka" == "$TEST_TMPDIR/two_a.kubeconfig" && "$kb" == "$TEST_TMPDIR/two_b.kubeconfig" ]] \
    || { echo "FAIL: KUBECONFIG is not \$TEST_TMPDIR/<name>.kubeconfig" >&2; exit 1; }
[[ -f "$ka" && -f "$kb" ]] || { echo "FAIL: a kubeconfig file is missing" >&2; exit 1; }
echo "PASS: each env file names its own kubeconfig"

for n in two_a two_b; do
    kc=$(envvar $n KUBECONFIG); want=$(envvar $n KUBE_API_SERVER)
    got=$("$KUBECTL" config view --minify --kubeconfig "$kc" -o jsonpath='{.clusters[0].cluster.server}')
    [[ "$got" == "$want" ]] || { echo "FAIL: $n's kubeconfig points at $got, its env file says $want" >&2; exit 1; }
    ctx=$("$KUBECTL" config current-context --kubeconfig "$kc")
    [[ "$ctx" == "kind-$(envvar $n KIND_CLUSTER_NAME)" ]] \
        || { echo "FAIL: $n's kubeconfig context is $ctx, not kind-$(envvar $n KIND_CLUSTER_NAME)" >&2; exit 1; }
done
[[ "$(envvar two_a KUBE_API_SERVER)" != "$(envvar two_b KUBE_API_SERVER)" ]] \
    || { echo "FAIL: both env files name the same API server" >&2; exit 1; }
echo "PASS: each kubeconfig points at its own cluster"

"$KUBECTL" create namespace only-in-a --kubeconfig "$ka" >/dev/null
"$KUBECTL" get namespace only-in-a --kubeconfig "$ka" >/dev/null
if "$KUBECTL" get namespace only-in-a --kubeconfig "$kb" >/dev/null 2>&1; then
    echo "FAIL: a namespace created through two_a is visible through two_b" >&2; exit 1
fi
echo "PASS: the clusters are separate"

# The same target name from another package: fails before creating anything.
cp "$TEST_TMPDIR/two_a.env" "$TEST_TMPDIR/two_a.env.before"
rc=0; timeout 120 "$clash_bin" > "$TEST_TMPDIR/clash.log" 2>&1 || rc=$?
[[ $rc != 0 && $rc != 124 ]] || { cat "$TEST_TMPDIR/clash.log" >&2; echo "FAIL: the clashing cluster did not fail at once (exit $rc)" >&2; exit 1; }
grep -qF 'kind_cluster //tests/clash:two_a: $TEST_TMPDIR/two_a.env and two_a.kubeconfig are already used by //tests:two_a' "$TEST_TMPDIR/clash.log" \
    || { cat "$TEST_TMPDIR/clash.log" >&2; echo "FAIL: the clash error does not name both targets" >&2; exit 1; }
cmp -s "$TEST_TMPDIR/two_a.env" "$TEST_TMPDIR/two_a.env.before" || { echo "FAIL: the clash changed two_a's env file" >&2; exit 1; }
"$KUBECTL" get namespace only-in-a --kubeconfig "$ka" >/dev/null || { echo "FAIL: two_a's kubeconfig no longer reaches two_a" >&2; exit 1; }
echo "PASS: a same-named cluster fails at once, naming both"

echo "PASS"
