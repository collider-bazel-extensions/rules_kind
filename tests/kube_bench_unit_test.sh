#!/usr/bin/env bash
set -euo pipefail
# Runs tests/kube_bench_unit_test.py (no cluster, no network).
RUNFILES="${TEST_SRCDIR:-${RUNFILES_DIR:-${BASH_SOURCE[0]}.runfiles}}"
root="${RUNFILES}/_main"
[[ -d "$root" ]] || root="${RUNFILES}/rules_kind"
exec python3 -B -I "$root/tests/kube_bench_unit_test.py" \
    "$root/private/kube_bench.py" \
    "$root/tests/kube_bench/control-plane.json" \
    "$root/tests/kube_bench/worker.json" \
    "$root/tests/kube_bench/kind_ignore.yaml"
