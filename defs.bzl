"""Public API for rules_kind.

Load all public symbols from this file:

    load("@rules_kind//:defs.bzl",
        "kind_cluster",
        "kind_health_check",
    )
"""

load("//private:binary.bzl",
    _KindBinaryInfo = "KindBinaryInfo",
)
load("//private:cluster.bzl",
    _kind_cluster_rule  = "kind_cluster_rule",
    _kind_health_check  = "kind_health_check",
)

# Re-export provider.
KindBinaryInfo = _KindBinaryInfo

# Re-export rules.
kind_health_check = _kind_health_check

# Map k8s_version -> //:kind_<MMM> binary label. Keep in sync with
# private/cluster.bzl::_KINDEST_NODE_VERSIONS and the kind_binary targets in
# //BUILD.bazel.
_BINARY_BY_VERSION = {
    "1.29": "@rules_kind//:kind_1_29",
    "1.32": "@rules_kind//:kind_1_32",
}

def kind_cluster(name, k8s_version = "1.29", **kwargs):
    """Long-running kind cluster for rules_itest integration tests.

    Picks the right kind+kubectl binary pair for `k8s_version` and forwards to
    the underlying rule. Supported versions: see `_BINARY_BY_VERSION`.
    """
    binary = _BINARY_BY_VERSION.get(k8s_version)
    if binary == None:
        fail("kind_cluster: unsupported k8s_version '{}'. Supported: {}".format(
            k8s_version, ", ".join(sorted(_BINARY_BY_VERSION.keys()))))
    _kind_cluster_rule(
        name        = name,
        k8s_version = k8s_version,
        binary      = binary,
        **kwargs
    )
