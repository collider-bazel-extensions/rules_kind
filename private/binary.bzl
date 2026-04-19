"""KindBinaryInfo provider and kind_binary rule."""

# ---------------------------------------------------------------------------
# Provider
# ---------------------------------------------------------------------------

KindBinaryInfo = provider(
    doc = "Carries the paths to the kind and kubectl binaries.",
    fields = {
        "kind":      "File: kind binary",
        "kubectl":   "File: kubectl binary",
        "version":   "string: Kubernetes minor version (e.g. '1.29')",
        "all_files": "depset: both binaries (for runfiles)",
    },
)

# ---------------------------------------------------------------------------
# kind_binary_files — injected into each binary repo's BUILD file
# ---------------------------------------------------------------------------

def _kind_binary_files_impl(ctx):
    """Find kind and kubectl in a flat list of binary files.

    When bins is empty the target is a non-host-platform stub repo; return an
    empty provider — the select() in BUILD.bazel will never choose this target
    on the wrong platform.
    """
    bins = {f.basename: f for f in ctx.files.bins}

    if not bins:
        return [
            KindBinaryInfo(
                kind      = None,
                kubectl   = None,
                version   = ctx.attr.version,
                all_files = depset([]),
            ),
            DefaultInfo(files = depset([])),
        ]

    kind_bin    = bins.get("kind")
    kubectl_bin = bins.get("kubectl")

    for name, f in [("kind", kind_bin), ("kubectl", kubectl_bin)]:
        if f == None:
            fail("kind_binary_files: '{}' not found in bins. Available: {}".format(
                name, sorted(bins.keys())))

    return [
        KindBinaryInfo(
            kind      = kind_bin,
            kubectl   = kubectl_bin,
            version   = ctx.attr.version,
            all_files = depset([kind_bin, kubectl_bin]),
        ),
        DefaultInfo(files = depset([kind_bin, kubectl_bin])),
    ]

kind_binary_files = rule(
    doc = """\
Internal rule injected into each binary repo's BUILD file.
Finds kind and kubectl by basename and exposes them via KindBinaryInfo.
""",
    implementation = _kind_binary_files_impl,
    attrs = {
        "bins":    attr.label_list(allow_files = True, mandatory = True),
        "version": attr.string(mandatory = True),
    },
)

# ---------------------------------------------------------------------------
# kind_binary — user-facing rule that selects the right repo
# ---------------------------------------------------------------------------

def _kind_binary_impl(ctx):
    """Pass-through: wraps a platform-selected kind_binary_files target."""
    info = ctx.attr.binary[KindBinaryInfo]
    return [
        info,
        DefaultInfo(files = info.all_files),
    ]

kind_binary = rule(
    doc = """\
Platform-agnostic kind binary target. Wraps a select() over
platform-specific kind_binary_files targets and re-exposes KindBinaryInfo
so consuming rules see a single label regardless of platform.
""",
    implementation = _kind_binary_impl,
    attrs = {
        "binary": attr.label(
            doc       = "Platform-selected kind_binary_files target.",
            mandatory = True,
            providers = [KindBinaryInfo],
        ),
    },
)
