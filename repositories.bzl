"""Legacy WORKSPACE equivalents of extensions.bzl.

For Bzlmod users, use extensions.bzl instead.
"""

load(":extensions.bzl",
    "PLATFORMS",
    "kind_system_binary_repo",
    "kind_binary_repo",
)

def kind_system_dependencies(versions, bin_dir = ""):
    """Declare kind + kubectl binary repos using host-installed binaries.

    Equivalent to kind.system() in MODULE.bazel.

    Args:
        versions: list of Kubernetes minor version strings (e.g. ["1.29"]).
        bin_dir:  directory containing kind and kubectl binaries.
                  Omit to auto-detect from PATH and common locations.
    """
    for version in versions:
        for platform in PLATFORMS:
            repo_name = "kind_{}_{}".format(version.replace(".", "_"), platform)
            kind_system_binary_repo(
                name     = repo_name,
                version  = version,
                bin_dir  = bin_dir,
                platform = platform,
            )

def kind_dependencies(versions):
    """Declare kind + kubectl binary repos by downloading from GitHub.

    Equivalent to kind.version() in MODULE.bazel.

    Args:
        versions: list of Kubernetes minor version strings (e.g. ["1.29"]).
    """
    for version in versions:
        for platform in PLATFORMS:
            repo_name = "kind_{}_{}".format(version.replace(".", "_"), platform)
            kind_binary_repo(
                name     = repo_name,
                version  = version,
                platform = platform,
            )
