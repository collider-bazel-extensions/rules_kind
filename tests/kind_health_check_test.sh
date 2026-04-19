#!/usr/bin/env bash
set -euo pipefail

# Test kind_health_check behavior:
#   1. Exits non-zero when the env file does not exist.
#   2. Exits 0 when the env file is present.

require_env() {
    [[ -n "${!1:-}" ]] || { echo "ERROR: \$$1 not set" >&2; exit 1; }
}

require_env TEST_TMPDIR

RUNFILES="${TEST_SRCDIR:-${RUNFILES_DIR:-${BASH_SOURCE[0]}.runfiles}}"

# Locate the health check binary — search all workspace prefixes.
health_check=""
for candidate in \
    "${RUNFILES}/_main/tests/test_cluster_health_health_check.sh" \
    "${RUNFILES}/rules_kind/tests/test_cluster_health_health_check.sh"
do
    if [[ -f "$candidate" ]]; then
        health_check="$candidate"
        break
    fi
done

if [[ -z "$health_check" ]]; then
    echo "ERROR: health check script not found under RUNFILES=$RUNFILES" >&2
    find "${RUNFILES}" -name "*health_check*" 2>/dev/null | head -10 >&2
    exit 1
fi

env_file="${TEST_TMPDIR}/test_cluster.env"

# 1. Env file absent → health check must exit non-zero.
rm -f "$env_file"
if "$health_check"; then
    echo "FAIL: health check should exit non-zero when env file is absent" >&2
    exit 1
fi
echo "PASS: health check exits non-zero without env file"

# 2. Env file present → health check must exit 0.
echo "KUBECONFIG=/dev/null" > "$env_file"
if ! "$health_check"; then
    echo "FAIL: health check should exit 0 when env file is present" >&2
    exit 1
fi
echo "PASS: health check exits 0 when env file is present"

echo "PASS"
