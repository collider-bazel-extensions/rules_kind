#!/usr/bin/env bash
# Consumer check against the commit's release archive (git archive honours
# .gitattributes export-ignore, as GitHub's tag tarballs do): the
# export-ignore'd directories are not shipped, @rules_kind//... loads for a
# consumer, and a consumer's kube_bench_test builds.
# Usage: .github/consumer/check.sh <scratch dir>
set -euo pipefail
module="rules_kind"
ignored=(tests)
repo="$(cd "$(dirname "$0")/../.." && pwd)"
work="$1"
src="$work/$module"
c="$work/consumer"
rm -rf "$work"; mkdir -p "$src" "$c"
git -C "$repo" archive HEAD | tar -x -C "$src"
for d in "${ignored[@]}"; do
    if [[ -e "$src/$d" ]]; then echo "FAIL: archive contains $d/" >&2; exit 1; fi
done
# This module's non-dev git_overrides apply only when it is the root, so the
# consumer repeats them (e.g. rules_kubectl).
overrides="$(python3 - "$src/MODULE.bazel" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
out = []
for m in re.finditer(r'bazel_dep\(([^)]*)\)\s*\n\s*(git_override\([^)]*\))', s):
    if "dev_dependency" in m.group(1):
        continue
    out.append("bazel_dep(" + m.group(1) + ")\n" + m.group(2))
print("\n".join(out))
PY
)"
if [[ -f "$repo/.bazelversion" ]]; then cp "$repo/.bazelversion" "$c/"; fi
cat > "$c/MODULE.bazel" <<MOD
module(name = "consumer")
bazel_dep(name = "$module")
local_path_override(module_name = "$module", path = "$src")
$overrides
MOD
# kube_bench_test with only rules_kind as a dependency (no rules_oci): the
# digest-pinned kube-bench image is fetched and the ignore file is checked
# by the build (validation action). Building runs no cluster.
cat > "$c/BUILD.bazel" <<'BUILD'
load("@rules_kind//:defs.bzl", "kind_cluster", "kube_bench_test")

kind_cluster(
    name = "k8s",
    images = ["@rules_kind//:kube_bench_image"],
    tags = ["manual", "no-sandbox", "requires-docker"],
)

kube_bench_test(
    name = "cis_test",
    cluster = ":k8s",
    ignore = "kube_bench_ignore.yaml",
)
BUILD
cat > "$c/kube_bench_ignore.yaml" <<'YAML'
checks:
  - id: "1.2.15"
    reason: consumer check
YAML
cd "$c"
bazel query "@$module//..." >/dev/null
bazel build //:cis_test
echo "PASS: ${ignored[*]} not shipped; @$module//... loads; kube_bench_test builds"
