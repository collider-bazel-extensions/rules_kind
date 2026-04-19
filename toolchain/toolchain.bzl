"""Toolchain type and registration helpers for rules_kind."""

load("//private:binary.bzl", "KindBinaryInfo")

# The toolchain type URL.
KIND_TOOLCHAIN_TYPE = "@rules_kind//toolchain:kind"

def _kind_toolchain_impl(ctx):
    binary_info = ctx.attr.kind_binary[KindBinaryInfo]
    toolchain_info = platform_common.ToolchainInfo(
        kind_binary_info = binary_info,
    )
    return [toolchain_info]

kind_toolchain = rule(
    doc = "Declares a kind toolchain carrying the kind and kubectl binaries.",
    implementation = _kind_toolchain_impl,
    attrs = {
        "kind_binary": attr.label(
            doc       = "A kind_binary target.",
            mandatory = True,
            providers = [KindBinaryInfo],
        ),
    },
)

def register_kind_toolchains():
    """Register the default rules_kind toolchains.

    Call this from WORKSPACE after loading repositories.bzl.
    Not required when using Bzlmod.
    """
    native.register_toolchains("@rules_kind//:kind_toolchain")
