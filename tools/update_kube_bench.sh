#!/usr/bin/env bash
# Maintainer-time script: print the pins for a kube-bench release image, for
# private/kube_bench_versions.bzl (KUBE_BENCH), and list the CIS benchmarks
# in its cfg/ directory.
#
#   tools/update_kube_bench.sh v0.16.0
#
# Reads Docker Hub's aquasec/kube-bench:<tag>: the multi-arch index digest
# (the registry's Docker-Content-Digest, cross-checked against the sha256 of
# the bytes) and the linux/amd64 and linux/arm64 manifest digests it lists.
# With podman or docker on PATH it also runs the amd64 image by digest and
# lists cfg/ and config.yaml's version_mapping, to check that the benchmarks
# KUBE_BENCH_CIS_BENCHMARKS / KUBE_BENCH_AUTO_BENCHMARK name are there.
# Edit kube_bench_versions.bzl by hand from the output, then run
# //tests:kube_bench_test.
set -euo pipefail

tag="${1:?usage: tools/update_kube_bench.sh <tag, e.g. v0.16.0>}"
repo="aquasec/kube-bench"
for tool in curl python3 sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || { echo "update_kube_bench: needs $tool on PATH" >&2; exit 1; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

token=$(curl -fsS "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" |
    python3 -I -c 'import json,sys; print(json.load(sys.stdin)["token"])')
curl -fsS -D "$work/headers" -o "$work/index.json" \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json" \
    "https://registry-1.docker.io/v2/${repo}/manifests/${tag}"

header=$(tr -d '\r' < "$work/headers" | awk -F': ' 'tolower($1) == "docker-content-digest" {print $2}')
computed="sha256:$(sha256sum "$work/index.json" | cut -d' ' -f1)"
if [[ "$header" != "$computed" ]]; then
    echo "update_kube_bench: registry says $header, bytes hash to $computed" >&2
    exit 1
fi

python3 -I - "$work/index.json" "$tag" "$computed" <<'EOF'
import json, sys
path, tag, digest = sys.argv[1:]
index = json.load(open(path))
want = {("linux", "amd64"): "linux_amd64", ("linux", "arm64"): "linux_arm64"}
found = {}
for m in index.get("manifests", []):
    p = m.get("platform", {})
    key = (p.get("os"), p.get("architecture"))
    if key in want and not p.get("variant"):
        found[want[key]] = m["digest"]
missing = sorted(set(want.values()) - set(found))
if missing:
    sys.exit("update_kube_bench: index has no manifest for " + ", ".join(missing))
print('KUBE_BENCH = {')
print('    "version": "{}",'.format(tag.lstrip("v")))
print('    "repository": "aquasec/kube-bench",')
print('    "tag": "{}",'.format(tag))
print('    "index_digest": "{}",'.format(digest))
print('    "manifests": {')
for k in sorted(found):
    print('        "{}": "{}",'.format(k, found[k]))
print('    },')
print('}')
EOF

rt=""
for c in podman docker; do
    command -v "$c" >/dev/null 2>&1 && { rt="$c"; break; }
done
if [[ -z "$rt" ]]; then
    echo "(no podman or docker: not listing cfg/)" >&2
    exit 0
fi
echo
echo "cfg/ in docker.io/${repo}@${computed} (linux/amd64):"
"$rt" run --rm --platform linux/amd64 --entrypoint sh "docker.io/${repo}@${computed}" -c \
    'ls /opt/kube-bench/cfg | grep -E "^cis-" | sort -V | tr "\n" " "; echo;
     echo "version_mapping:"; sed -n "/^version_mapping:/,/^target_mapping:/p" /opt/kube-bench/cfg/config.yaml | grep -E "\"1\.[0-9]+\":"'
