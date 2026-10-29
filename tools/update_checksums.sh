#!/usr/bin/env bash
# Maintainer-time script: re-pin every kind_sha256 / kubectl_sha256 in
# extensions.bzl's _KIND_VERSIONS table from the published release sums.
#
#   kind:    <kind_url>.sha256sum   (asset on the kubernetes-sigs/kind release)
#   kubectl: <kubectl_url>.sha256   (dl.k8s.io)
#
# Each published value is cross-checked by downloading the binary and
# hashing it; any mismatch aborts without touching extensions.bzl.
#
# Usage:  tools/update_checksums.sh           # rewrite extensions.bzl
#         tools/update_checksums.sh --check   # verify only, exit 1 on drift
set -euo pipefail

cd "$(dirname "$0")/.."
check_only=0
[[ "${1:-}" == "--check" ]] && check_only=1

for tool in curl sha256sum python3; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "update_checksums: needs $tool on PATH" >&2
        exit 1
    }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# One "<url> <sha_key>" pair per line, in table order.
python3 -I - extensions.bzl > "$work/urls" <<'EOF'
import re, sys
text = open(sys.argv[1]).read()
for m in re.finditer(r'"(kind|kubectl)_url":\s*"([^"]+)"', text):
    print(m.group(2), m.group(1) + "_sha256")
EOF

: > "$work/pins"
while read -r url key; do
    if [[ "$key" == kind_sha256 ]]; then sum_url="$url.sha256sum"; else sum_url="$url.sha256"; fi
    published=$(curl -fsSL "$sum_url" | awk '{print $1}')
    if [[ ! "$published" =~ ^[0-9a-f]{64}$ ]]; then
        echo "update_checksums: no SHA-256 at $sum_url" >&2
        exit 1
    fi
    curl -fsSL -o "$work/bin" "$url"
    actual=$(sha256sum "$work/bin" | awk '{print $1}')
    if [[ "$published" != "$actual" ]]; then
        echo "update_checksums: $url hashes to $actual, published $published" >&2
        exit 1
    fi
    echo "$url $published" >> "$work/pins"
    echo "  $published  $url"
done < "$work/urls"

python3 -I - extensions.bzl "$work/pins" "$check_only" <<'EOF'
import re, sys
path, pins_path, check_only = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
pins = dict(line.split() for line in open(pins_path) if line.strip())
text = open(path).read()
pat = re.compile(r'("(kind|kubectl)_url":\s*"([^"]+)",\n\s*"(?:kind|kubectl)_sha256":\s*)"[^"]*"')
new = pat.sub(lambda m: m.group(1) + '"%s"' % pins[m.group(3)], text)
if check_only:
    if new != text:
        sys.exit("update_checksums: extensions.bzl differs from the published sums")
    print("update_checksums: extensions.bzl matches the published sums")
else:
    open(path, "w").write(new)
    print("update_checksums: wrote " + path)
EOF
