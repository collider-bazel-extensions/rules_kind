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
    _kind_cluster       = "kind_cluster",
    _kind_health_check  = "kind_health_check",
)

# Re-export provider.
KindBinaryInfo = _KindBinaryInfo

# Re-export rules.
kind_cluster      = _kind_cluster
kind_health_check = _kind_health_check
