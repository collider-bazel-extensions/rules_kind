#!/usr/bin/env bash
set -euo pipefail

# The rules_itest failure case: the launcher is SIGKILLed and the test
# exits straight away, while the cluster still exists. Bazel then kills
# every process the test left behind, so only a reaper that isn't one of
# them (a systemd user unit) can delete the cluster. This test can't see
# that happen: CI's "No kind clusters left behind" step checks it after
# `bazel test` returns.

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

env_file="${TEST_TMPDIR}/test_cluster.env"
rm -f "$env_file"
"$cluster_launcher" &
pid=$!
deadline=$(( $(date +%s) + 180 ))
while [[ ! -f "$env_file" ]]; do
    if [[ $(date +%s) -gt $deadline ]]; then
        echo "FAIL: env file not written within 180 seconds" >&2
        exit 1
    fi
    kill -0 "$pid" 2>/dev/null || { echo "FAIL: launcher exited early" >&2; exit 1; }
    sleep 2
done
name=$(sed -n 's/^KIND_CLUSTER_NAME=//p' "$env_file")
kill -KILL "$pid"
echo "PASS: SIGKILLed the launcher of $name; exiting before it is deleted"
