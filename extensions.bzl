"""Bzlmod module extension: fetch or symlink kind + kubectl binaries."""

# kind_version + kubectl version pairs per Kubernetes minor version.
# kind binaries: https://github.com/kubernetes-sigs/kind/releases
# kubectl binaries: https://dl.k8s.io/release/v{k8s_version}/bin/{os}/{arch}/kubectl
# SHA-256 values are placeholders — pin real values before using kind.version().
_KIND_VERSIONS = {
    "1.29": {
        "kind_version": "0.22.0",
        "kubectl_version": "1.29.2",
        "linux_amd64": {
            "kind_url":      "https://github.com/kubernetes-sigs/kind/releases/download/v0.22.0/kind-linux-amd64",
            "kind_sha256":   "",  # placeholder: run tools/update_checksums.sh
            "kubectl_url":   "https://dl.k8s.io/release/v1.29.2/bin/linux/amd64/kubectl",
            "kubectl_sha256": "",  # placeholder
        },
        "darwin_arm64": {
            "kind_url":      "https://github.com/kubernetes-sigs/kind/releases/download/v0.22.0/kind-darwin-arm64",
            "kind_sha256":   "",  # placeholder
            "kubectl_url":   "https://dl.k8s.io/release/v1.29.2/bin/darwin/arm64/kubectl",
            "kubectl_sha256": "",  # placeholder
        },
        "darwin_amd64": {
            "kind_url":      "https://github.com/kubernetes-sigs/kind/releases/download/v0.22.0/kind-darwin-amd64",
            "kind_sha256":   "",  # placeholder
            "kubectl_url":   "https://dl.k8s.io/release/v1.29.2/bin/darwin/amd64/kubectl",
            "kubectl_sha256": "",  # placeholder
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
                "SHA-256 for {} k8s {} on {} is a placeholder. " +
                "Run tools/update_checksums.sh to pin real values.".format(
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

def _check_container_runtime(rctx):
    """Fail at analysis time with a clear message if no container runtime is found.

    Only runs on the host platform; stubs skip this check.
    """
    docker_ok = rctx.execute(["docker", "info"], timeout = 5).return_code == 0
    if docker_ok:
        return

    podman_ok = rctx.execute(
        ["podman", "--runtime", "/usr/bin/crun", "info"], timeout = 5,
    ).return_code == 0
    if podman_ok:
        return

    docker_found = rctx.execute(["sh", "-c", "command -v docker"]).return_code == 0
    podman_found = rctx.execute(["sh", "-c", "command -v podman"]).return_code == 0

    if docker_found:
        docker_detail = "docker is installed but 'docker info' failed — is the daemon running?"
    else:
        docker_detail = "docker not found in PATH"

    if podman_found:
        podman_detail = "podman is installed but 'podman info' failed — check podman configuration"
    else:
        podman_detail = "podman not found in PATH"

    fail(
        "\n\nrules_kind requires a container runtime (Docker or podman).\n" +
        "kind uses it to run Kubernetes node containers.\n\n" +
        "What was found:\n" +
        "  docker: " + docker_detail + "\n" +
        "  podman: " + podman_detail + "\n\n" +
        "Install one of:\n" +
        "  Docker  — https://docs.docker.com/engine/install/\n" +
        "            Ubuntu/Debian: sudo apt install docker.io\n" +
        "            Fedora/RHEL:   sudo dnf install docker\n" +
        "  podman  — https://podman.io/docs/installation\n" +
        "            Ubuntu/Debian: sudo apt install podman\n" +
        "            Fedora/RHEL:   sudo dnf install podman\n\n" +
        "After installing, verify with: docker info   or   podman info\n"
    )

def _kind_system_binary_repo_impl(rctx):
    version  = rctx.attr.version
    bin_dir  = rctx.attr.bin_dir
    platform = rctx.attr.platform

    # If this repo's platform doesn't match the host OS, emit a stub.
    expected_os = _PLATFORM_OS_MAP.get(platform, "")
    if expected_os and rctx.os.name.lower() != expected_os:
        rctx.file("BUILD.bazel", _STUB_BUILD)
        return

    _check_container_runtime(rctx)

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
    for mod in module_ctx.modules:
        for tag in mod.tags.version:
            for version in tag.versions:
                for platform in PLATFORMS:
                    repo_name = "kind_{}_{}".format(
                        version.replace(".", "_"), platform)
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
