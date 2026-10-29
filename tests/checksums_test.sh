#!/usr/bin/env bash
# Fails when any kind / kubectl entry in extensions.bzl's _KIND_VERSIONS
# table lacks a 64-hex SHA-256, or when a URL has no checksum beside it.
# No network, no container runtime: runs in every CI job.
set -euo pipefail

ext="${TEST_SRCDIR}/_main/extensions.bzl"
[[ -f "$ext" ]] || ext="$(dirname "$0")/../extensions.bzl"

urls=$(grep -cE '"(kind|kubectl)_url":' "$ext" || true)
shas=$(grep -cE '"(kind|kubectl)_sha256":' "$ext" || true)
pinned=$(grep -cE '"(kind|kubectl)_sha256":[[:space:]]*"[0-9a-f]{64}"' "$ext" || true)

echo "urls=$urls sha256_fields=$shas pinned=$pinned"

if [[ "$urls" -eq 0 ]]; then
    echo "FAIL: no kind/kubectl URLs found in $ext" >&2
    exit 1
fi
if [[ "$shas" -ne "$urls" || "$pinned" -ne "$urls" ]]; then
    echo "FAIL: every URL needs a 64-hex SHA-256; offending entries:" >&2
    grep -nE '"(kind|kubectl)_sha256":' "$ext" \
        | grep -vE '"[0-9a-f]{64}"' >&2 || true
    echo "Run tools/update_checksums.sh to pin real values." >&2
    exit 1
fi
echo "PASS"
