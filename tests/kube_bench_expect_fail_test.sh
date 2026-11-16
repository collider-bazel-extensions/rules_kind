#!/usr/bin/env bash
set -euo pipefail

# kube_bench_test's failure modes against one real kind cluster. Starts
# :kube_bench_fail_cluster, then runs four kube_bench_test targets on it (each
# finds the cluster's env file and uses the running cluster):
#   kube_bench_pass      kind_ignore.yaml + a stale entry      -> passes, lists it as stale
#   kube_bench_unlisted  kind_ignore.yaml without 1.2.15       -> fails, naming 1.2.15
#   kube_bench_expired   1.2.15 with expires: 2020-01-01       -> fails, naming the entry
#   kube_bench_stale     the stale entry, fail_on_stale = True -> fails, naming it

[[ -n "${TEST_TMPDIR:-}" ]] || { echo "ERROR: \$TEST_TMPDIR not set" >&2; exit 1; }
RUNFILES="${TEST_SRCDIR:-${RUNFILES_DIR:-${BASH_SOURCE[0]}.runfiles}}"

find_runfile() {
    local c
    for c in "${RUNFILES}/_main/tests/$1" "${RUNFILES}/rules_kind/tests/$1"; do
        [[ -f "$c" ]] && { echo "$c"; return 0; }
    done
    echo "ERROR: $1 not found under $RUNFILES" >&2
    return 1
}

launcher=$(find_runfile kube_bench_fail_cluster_kind_cluster.sh)
env_file="${TEST_TMPDIR}/kube_bench_fail_cluster.env"
rm -f "$env_file"
"$launcher" &
pid=$!
trap 'kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true' EXIT

deadline=$(( $(date +%s) + 600 ))
while [[ ! -f "$env_file" ]]; do
    [[ $(date +%s) -le $deadline ]] || { echo "FAIL: env file not written within 600 s (slot wait included)" >&2; exit 1; }
    kill -0 "$pid" 2>/dev/null || { echo "FAIL: launcher exited before writing env file" >&2; exit 1; }
    sleep 2
done

failures=0

# run_case <target> <want exit: 0|1> <pattern that must appear>...
run_case() {
    local target="$1" want="$2"
    shift 2
    local bin out rc
    bin=$(find_runfile "${target}.kube_bench_test.sh")
    out="${TEST_TMPDIR}/${target}.out"
    mkdir -p "${TEST_TMPDIR}/${target}.outputs"
    echo "=== $target (want exit $want)"
    set +e
    TEST_UNDECLARED_OUTPUTS_DIR="${TEST_TMPDIR}/${target}.outputs" "$bin" > "$out" 2>&1
    rc=$?
    set -e
    sed 's/^/    /' "$out"
    if [[ "$want" == 0 && "$rc" -ne 0 ]] || [[ "$want" != 0 && "$rc" -eq 0 ]]; then
        echo "FAIL: $target exited $rc, want $([[ "$want" == 0 ]] && echo 0 || echo non-zero)" >&2
        failures=$((failures + 1))
    fi
    local p
    for p in "$@"; do
        if ! grep -qE -- "$p" "$out"; then
            echo "FAIL: $target output lacks /$p/" >&2
            failures=$((failures + 1))
        fi
    done
    # Every run writes each node's raw JSON.
    if ! ls "${TEST_TMPDIR}/${target}.outputs/kube-bench/"*.json >/dev/null 2>&1; then
        echo "FAIL: $target wrote no kube-bench JSON" >&2
        failures=$((failures + 1))
    fi
}

run_case kube_bench_pass 0 \
    '^PASS: no FAIL outside' \
    '^Ignored FAIL \(12\):' \
    '^Stale ignore entries \(1\)' \
    '^  1[.]1[.]1: PASS on .*control-plane -- reason: stale on purpose' \
    'using the running cluster'

run_case kube_bench_unlisted 1 \
    '^FAIL, not in tests/kube_bench/unlisted_ignore[.]yaml \(1\):' \
    '^  1[.]2[.]15 Ensure that the --profiling argument is set to false' \
    '^      --profiling=false' \
    '^FAIL: 1 failing check\(s\) not in tests/kube_bench/unlisted_ignore[.]yaml: 1[.]2[.]15$'

run_case kube_bench_expired 1 \
    '^Expired ignore entries \(1\):' \
    '^  1[.]2[.]15: expired 2020-01-01 -- reason: kube-apiserver keeps' \
    '^FAIL: 1 expired ignore entry: 1[.]2[.]15$'

run_case kube_bench_stale 1 \
    '^Stale ignore entries \(1, failing the test \(fail_on_stale\)\)' \
    '^FAIL: 1 stale ignore entry: 1[.]1[.]1$'

trap '' EXIT
kill "$pid"
wait "$pid" || true

if [[ "$failures" -ne 0 ]]; then
    echo "FAIL: $failures problem(s)" >&2
    exit 1
fi
echo "PASS"
