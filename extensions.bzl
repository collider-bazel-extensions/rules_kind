"""Bzlmod module extension: fetch or symlink kind + kubectl binaries."""

# kind_version + kubectl version pairs per Kubernetes minor version.
# kind binaries: https://github.com/kubernetes-sigs/kind/releases
# kubectl binaries: https://dl.k8s.io/release/v{k8s_version}/bin/{os}/{arch}/kubectl
# SHA-256 values are the published release sums (kind: <asset>.sha256sum on the
# GitHub release; kubectl: <url>.sha256 on dl.k8s.io). Regenerate them with
# tools/update_checksums.sh; //tests:checksums_test fails on an empty value.
_KIND_VERSIONS = {
    "1.29": {
        "kind_version": "0.22.0",
        "kubectl_version": "1.29.2",
        "linux_amd64": {
            "kind_url":      "https://github.com/kubernetes-sigs/kind/releases/download/v0.22.0/kind-linux-amd64",
            "kind_sha256":   "e4264d7ee07ca642fe52818d7c0ed188b193c214889dd055c929dbcb968d1f62",
            "kubectl_url":   "https://dl.k8s.io/release/v1.29.2/bin/linux/amd64/kubectl",
            "kubectl_sha256": "7816d067740f47f949be826ac76943167b7b3a38c4f0c18b902fffa8779a5afa",
        },
        "darwin_arm64": {
            "kind_url":      "https://github.com/kubernetes-sigs/kind/releases/download/v0.22.0/kind-darwin-arm64",
            "kind_sha256":   "c8dd3b287965150ae4db668294edc48229116e95d94620c306d8fae932ee633f",
            "kubectl_url":   "https://dl.k8s.io/release/v1.29.2/bin/darwin/arm64/kubectl",
            "kubectl_sha256": "ce030f86625df96560402573d86d4e6f4b8b956ca3e3b9df57cb8ccf2b9a540c",
        },
        "darwin_amd64": {
            "kind_url":      "https://github.com/kubernetes-sigs/kind/releases/download/v0.22.0/kind-darwin-amd64",
            "kind_sha256":   "28a9f7ad7fd77922c639e21c034d0f989b33402693f4f842099cd9185b144d20",
            "kubectl_url":   "https://dl.k8s.io/release/v1.29.2/bin/darwin/amd64/kubectl",
            "kubectl_sha256": "bb04d9450d9c9fa120956c5cc7c8dfaa700297038ff9c941741e730b02bbd1f3",
        },
    },
    # k8s 1.32 added in v0.1.2 to unblock rules_cilium. kindest/node:v1.32.2
    # ships runc 1.2.5, which fixes the bind-mount-remount-RO EPERM bug under
    # rootless container engines + kernel 6.x that breaks kube-proxy and
    # Cilium's agent on the older 1.29.2 image (runc 1.1.12). Use 1.32 for new
    # workloads that depend on configmap mounts under user namespaces; existing
    # 1.29 consumers keep their pin.
    "1.32": {
        "kind_version": "0.27.0",
        "kubectl_version": "1.32.2",
        "linux_amd64": {
            "kind_url":      "https://github.com/kubernetes-sigs/kind/releases/download/v0.27.0/kind-linux-amd64",
            "kind_sha256":   "a6875aaea358acf0ac07786b1a6755d08fd640f4c79b7a2e46681cc13f49a04b",
            "kubectl_url":   "https://dl.k8s.io/release/v1.32.2/bin/linux/amd64/kubectl",
            "kubectl_sha256": "4f6a959dcc5b702135f8354cc7109b542a2933c46b808b248a214c1f69f817ea",
        },
        "darwin_arm64": {
            "kind_url":      "https://github.com/kubernetes-sigs/kind/releases/download/v0.27.0/kind-darwin-arm64",
            "kind_sha256":   "5240ca1acb587e1d0386532dd8c3373d81f5173b5af322919fc56f0cdd646596",
            "kubectl_url":   "https://dl.k8s.io/release/v1.32.2/bin/darwin/arm64/kubectl",
            "kubectl_sha256": "31b6318deaa72014b72121e1c7a2e12496d077cee49bbeda94250aec4c978ffb",
        },
        "darwin_amd64": {
            "kind_url":      "https://github.com/kubernetes-sigs/kind/releases/download/v0.27.0/kind-darwin-amd64",
            "kind_sha256":   "3435134325b6b9406ccfec417b13bb46a808fc74e9a2ebb0ca31b379c8293863",
            "kubectl_url":   "https://dl.k8s.io/release/v1.32.2/bin/darwin/amd64/kubectl",
            "kubectl_sha256": "371b8fbd481e1e9052ace16d9c243e92618a2ea9a18c1aaf235d35fef20c0c32",
        },
    },
    # k8s 1.35-1.37 added in v0.2.0: the supported Kubernetes minors as of
    # 2026-10 (1.29 and 1.32 are upstream EOL). All three use kind v0.33.0,
    # whose release notes list the matching kindest/node images.
    "1.35": {
        "kind_version": "0.33.0",
        "kubectl_version": "1.35.10",
        "linux_amd64": {
            "kind_url":      "https://github.com/kubernetes-sigs/kind/releases/download/v0.33.0/kind-linux-amd64",
            "kind_sha256":   "aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d",
            "kubectl_url":   "https://dl.k8s.io/release/v1.35.10/bin/linux/amd64/kubectl",
            "kubectl_sha256": "c49a28f1f4efc4d475ed05f47f2ce8e563bf7bef69ed77fe1b924ea6d83b6327",
        },
        "darwin_arm64": {
            "kind_url":      "https://github.com/kubernetes-sigs/kind/releases/download/v0.33.0/kind-darwin-arm64",
            "kind_sha256":   "0c8c7dbe5e23594a198b786c4bc13dacc101fa6196b0cb0b23a1ca44e61f4b4f",
            "kubectl_url":   "https://dl.k8s.io/release/v1.35.10/bin/darwin/arm64/kubectl",
            "kubectl_sha256": "77ec066f3404edb81760865c9cd812d03c25e9a89aa0349fd3c1aa60bd5fb068",
        },
        "darwin_amd64": {
            "kind_url":      "https://github.com/kubernetes-sigs/kind/releases/download/v0.33.0/kind-darwin-amd64",
            "kind_sha256":   "5a99f26f57246dc9319dd294803313197a0f34d33c525b3ea8b655db5916ece0",
            "kubectl_url":   "https://dl.k8s.io/release/v1.35.10/bin/darwin/amd64/kubectl",
            "kubectl_sha256": "4787e20d9029871845d8a57bf56f533870f5d98d9cf3b82b6f5e2ad5eaeee3a3",
        },
    },
    "1.36": {
        "kind_version": "0.33.0",
        "kubectl_version": "1.36.6",
        "linux_amd64": {
            "kind_url":      "https://github.com/kubernetes-sigs/kind/releases/download/v0.33.0/kind-linux-amd64",
            "kind_sha256":   "aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d",
            "kubectl_url":   "https://dl.k8s.io/release/v1.36.6/bin/linux/amd64/kubectl",
            "kubectl_sha256": "29818b6729dc9262b692307470d0558d027725e738be5dd47c760261868a2634",
        },
        "darwin_arm64": {
            "kind_url":      "https://github.com/kubernetes-sigs/kind/releases/download/v0.33.0/kind-darwin-arm64",
            "kind_sha256":   "0c8c7dbe5e23594a198b786c4bc13dacc101fa6196b0cb0b23a1ca44e61f4b4f",
            "kubectl_url":   "https://dl.k8s.io/release/v1.36.6/bin/darwin/arm64/kubectl",
            "kubectl_sha256": "1cf735c3d35ccfec28d0618784cb06a4614d2c42aade28b6be0eab76a2ffb623",
        },
        "darwin_amd64": {
            "kind_url":      "https://github.com/kubernetes-sigs/kind/releases/download/v0.33.0/kind-darwin-amd64",
            "kind_sha256":   "5a99f26f57246dc9319dd294803313197a0f34d33c525b3ea8b655db5916ece0",
            "kubectl_url":   "https://dl.k8s.io/release/v1.36.6/bin/darwin/amd64/kubectl",
            "kubectl_sha256": "2e22d382f2423c88d9d076246f860bb3d5c743dd279ca63e113474bb88382426",
        },
    },
    "1.37": {
        "kind_version": "0.33.0",
        "kubectl_version": "1.37.2",
        "linux_amd64": {
            "kind_url":      "https://github.com/kubernetes-sigs/kind/releases/download/v0.33.0/kind-linux-amd64",
            "kind_sha256":   "aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d",
            "kubectl_url":   "https://dl.k8s.io/release/v1.37.2/bin/linux/amd64/kubectl",
            "kubectl_sha256": "c04487523e7aa7d1493f7808174c899db93d7a9cf57531420cd76b9bd415f8f4",
        },
        "darwin_arm64": {
            "kind_url":      "https://github.com/kubernetes-sigs/kind/releases/download/v0.33.0/kind-darwin-arm64",
            "kind_sha256":   "0c8c7dbe5e23594a198b786c4bc13dacc101fa6196b0cb0b23a1ca44e61f4b4f",
            "kubectl_url":   "https://dl.k8s.io/release/v1.37.2/bin/darwin/arm64/kubectl",
            "kubectl_sha256": "55701af0d51815ee335f240e48acf0959c3c23017ed3fa816e880c4a92bae581",
        },
        "darwin_amd64": {
            "kind_url":      "https://github.com/kubernetes-sigs/kind/releases/download/v0.33.0/kind-darwin-amd64",
            "kind_sha256":   "5a99f26f57246dc9319dd294803313197a0f34d33c525b3ea8b655db5916ece0",
            "kubectl_url":   "https://dl.k8s.io/release/v1.37.2/bin/darwin/amd64/kubectl",
            "kubectl_sha256": "88379aff5c8111de6be0a394adffba2819e44cde269f3ab23cef76de1a48eaa8",
        },
    },
}

PLATFORMS = ["linux_amd64", "darwin_arm64", "darwin_amd64"]

_BINARY_REPO_BUILD = """\
filegroup(
    name = "kind_bin",
    srcs = ["kind"],
    visibility = ["//visibility:public"],
)
filegroup(
    name = "kubectl_bin",
    srcs = ["kubectl"],
    visibility = ["//visibility:public"],
)
filegroup(
    name = "all_files",
    srcs = [":kind_bin", ":kubectl_bin"],
    visibility = ["//visibility:public"],
)
"""

_STUB_BUILD = """\
# Stub repo for a non-host platform.  Never selected at build time.
filegroup(name = "kind_bin",   srcs = [], visibility = ["//visibility:public"])
filegroup(name = "kubectl_bin", srcs = [], visibility = ["//visibility:public"])
filegroup(name = "all_files",  srcs = [], visibility = ["//visibility:public"])
"""

# ---------------------------------------------------------------------------
# Downloaded binaries (kind.version())
# ---------------------------------------------------------------------------

def _kind_binary_repo_impl(rctx):
    version  = rctx.attr.version
    platform = rctx.attr.platform

    if version not in _KIND_VERSIONS:
        fail("Unsupported k8s version: {}. Supported: {}".format(
            version, ", ".join(_KIND_VERSIONS.keys())))

    info = _KIND_VERSIONS[version].get(platform)
    if not info:
        fail("No binaries for k8s {} on {}".format(version, platform))

    for key in ["kind_sha256", "kubectl_sha256"]:
        if not info[key]:
            fail(
                ("SHA-256 for {} k8s {} on {} is empty. " +
                 "Run tools/update_checksums.sh to pin real values.").format(
                    key, version, platform),
            )

    rctx.download(
        url        = info["kind_url"],
        output     = "kind",
        sha256     = info["kind_sha256"],
        executable = True,
    )
    rctx.download(
        url        = info["kubectl_url"],
        output     = "kubectl",
        sha256     = info["kubectl_sha256"],
        executable = True,
    )
    rctx.file("BUILD.bazel", _BINARY_REPO_BUILD)

kind_binary_repo = repository_rule(
    implementation = _kind_binary_repo_impl,
    attrs = {
        "version":  attr.string(mandatory = True),
        "platform": attr.string(mandatory = True),
    },
)

# ---------------------------------------------------------------------------
# System binaries (kind.system())
# ---------------------------------------------------------------------------

_PLATFORM_OS_MAP = {
    "linux_amd64":  "linux",
    "darwin_arm64": "mac os x",
    "darwin_amd64": "mac os x",
}

_KIND_SEARCH_PATHS = [
    "/usr/local/bin",
    "/usr/bin",
]

_KUBECTL_SEARCH_PATHS = [
    "/usr/local/bin",
    "/usr/bin",
]

# NOTE: pre-v0.1.4 had a `_check_container_runtime(rctx)` helper that
# called `docker info` / `podman info` at analysis time, intending to
# give a friendly upfront error. The side effect was that
# `bazel test //... --test_tag_filters=-manual` poisoned wildcard
# analysis on Docker-less hosts: tag filtering happens AFTER analysis,
# so analysis-time fail() contaminated unrelated test surfaces. v0.1.4
# drops the analysis-time probe entirely — `private/launcher.py` does
# the same probe at execution time (lines 105-150) with strictly more
# informative per-runtime messages, and runs only when a kind-using
# test is actually executed. Closes #6.

def _kind_system_binary_repo_impl(rctx):
    version  = rctx.attr.version
    bin_dir  = rctx.attr.bin_dir
    platform = rctx.attr.platform

    # If this repo's platform doesn't match the host OS, emit a stub.
    expected_os = _PLATFORM_OS_MAP.get(platform, "")
    if expected_os and rctx.os.name.lower() != expected_os:
        rctx.file("BUILD.bazel", _STUB_BUILD)
        return

    home = rctx.os.environ.get("HOME", "")

    # Auto-detect kind.
    kind_path = ""
    if bin_dir:
        kind_path = bin_dir + "/kind"
    else:
        result = rctx.execute(["sh", "-c", "command -v kind 2>/dev/null || true"])
        if result.return_code == 0 and result.stdout.strip():
            kind_path = result.stdout.strip()

    if not kind_path:
        search = _KIND_SEARCH_PATHS + ([home + "/.local/bin"] if home else [])
        for path in search:
            if rctx.execute(["test", "-f", path + "/kind"]).return_code == 0:
                kind_path = path + "/kind"
                break

    if not kind_path:
        fail(
            "kind not found in PATH or common locations.\n" +
            "Install with: brew install kind  (macOS)\n" +
            "              apt install kind   (Debian/Ubuntu)\n" +
            "Or pass bin_dir explicitly: kind.system(versions=[...], bin_dir='/path/to/bin')",
        )

    # Auto-detect kubectl.
    kubectl_path = ""
    if bin_dir:
        if rctx.execute(["test", "-f", bin_dir + "/kubectl"]).return_code == 0:
            kubectl_path = bin_dir + "/kubectl"

    if not kubectl_path:
        result = rctx.execute(["sh", "-c", "command -v kubectl 2>/dev/null || true"])
        if result.return_code == 0 and result.stdout.strip():
            kubectl_path = result.stdout.strip()

    if not kubectl_path:
        search = _KUBECTL_SEARCH_PATHS + ([home + "/.local/bin"] if home else [])
        for path in search:
            if rctx.execute(["test", "-f", path + "/kubectl"]).return_code == 0:
                kubectl_path = path + "/kubectl"
                break

    if not kubectl_path:
        fail(
            "kubectl not found in PATH or common locations.\n" +
            "Install with: brew install kubectl  (macOS)\n" +
            "              apt install kubectl   (Debian/Ubuntu)",
        )

    rctx.symlink(kind_path,    "kind")
    rctx.symlink(kubectl_path, "kubectl")
    rctx.file("BUILD.bazel", _BINARY_REPO_BUILD)

kind_system_binary_repo = repository_rule(
    implementation = _kind_system_binary_repo_impl,
    attrs = {
        "version":  attr.string(mandatory = True),
        "bin_dir":  attr.string(default = ""),
        "platform": attr.string(default = ""),
    },
)

# ---------------------------------------------------------------------------
# Module extension
# ---------------------------------------------------------------------------

_version_tag = tag_class(
    doc = "Download pre-built kind + kubectl binaries from GitHub / dl.k8s.io.",
    attrs = {
        "versions": attr.string_list(
            doc       = "Kubernetes minor versions (e.g. ['1.29']).",
            mandatory = True,
        ),
    },
)

_system_tag = tag_class(
    doc = "Use host-installed kind + kubectl binaries.",
    attrs = {
        "versions": attr.string_list(
            doc       = "Kubernetes minor versions to register (e.g. ['1.29']).",
            mandatory = True,
        ),
        "bin_dir": attr.string(
            doc     = "Directory containing kind and kubectl. " +
                      "Omit to auto-detect from PATH and common locations.",
            default = "",
        ),
    },
)

def _kind_extension(module_ctx):
    # Each repo name is declared once. module_ctx.modules lists the root
    # module first, so a consumer's kind.version(["1.29"]) takes precedence
    # over the kind.system(["1.29", "1.32"]) rules_kind registers for itself;
    # within one module, version() wins over system().
    declared = {}
    for mod in module_ctx.modules:
        for tag in mod.tags.version:
            for version in tag.versions:
                for platform in PLATFORMS:
                    repo_name = "kind_{}_{}".format(
                        version.replace(".", "_"), platform)
                    if repo_name in declared:
                        continue
                    declared[repo_name] = True
                    kind_binary_repo(
                        name     = repo_name,
                        version  = version,
                        platform = platform,
                    )

        for tag in mod.tags.system:
            for version in tag.versions:
                for platform in PLATFORMS:
                    repo_name = "kind_{}_{}".format(
                        version.replace(".", "_"), platform)
                    if repo_name in declared:
                        continue
                    declared[repo_name] = True
                    kind_system_binary_repo(
                        name     = repo_name,
                        version  = version,
                        bin_dir  = tag.bin_dir,
                        platform = platform,
                    )

kind = module_extension(
    implementation = _kind_extension,
    tag_classes    = {
        "version": _version_tag,
        "system":  _system_tag,
    },
)
