"""kind_cluster rule and kind_health_check rule."""

load(":binary.bzl", "KindBinaryInfo")

# ---------------------------------------------------------------------------
# JSON serialisation helpers
# ---------------------------------------------------------------------------

def _json_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

def _json_str_list(lst):
    return "[" + ", ".join([_json_str(s) for s in lst]) + "]"

# ---------------------------------------------------------------------------
# Supported k8s versions (for analysis-time validation) and the corresponding
# full kindest/node image tag to pass to kind create cluster --image.
# ---------------------------------------------------------------------------

_KINDEST_NODE_VERSIONS = {
    "1.29": "1.29.2",
}

_SUPPORTED_VERSIONS = list(_KINDEST_NODE_VERSIONS.keys())

# ---------------------------------------------------------------------------
# kind_cluster
# ---------------------------------------------------------------------------

def _kind_cluster_impl(ctx):
    binary_info = ctx.attr._binary[KindBinaryInfo]

    # Analysis-time validation.
    if ctx.attr.k8s_version not in _SUPPORTED_VERSIONS:
        fail("kind_cluster: unsupported k8s_version '{}'. Supported: {}".format(
            ctx.attr.k8s_version, ", ".join(_SUPPORTED_VERSIONS)))

    # Collect manifest file short_paths from the manifests attribute.
    manifest_short_paths = []
    for f in ctx.files.manifests:
        manifest_short_paths.append(f.short_path)

    # Collect image tarball short_paths from the images attribute.
    image_tarball_short_paths = []
    for f in ctx.files.images:
        image_tarball_short_paths.append(f.short_path)

    # Optional kind config file.
    kind_config_short = ""
    if ctx.file.config:
        kind_config_short = ctx.file.config.short_path

    # Build the launcher manifest JSON.
    node_version = _KINDEST_NODE_VERSIONS[ctx.attr.k8s_version]

    fields = [
        '  "workspace":        ' + _json_str(ctx.workspace_name),
        '  "kind_bin":         ' + _json_str(binary_info.kind.short_path),
        '  "kubectl_bin":      ' + _json_str(binary_info.kubectl.short_path),
        '  "k8s_version":      ' + _json_str(ctx.attr.k8s_version),
        '  "k8s_node_version": ' + _json_str(node_version),
    ]
    if kind_config_short:
        fields.append('  "kind_config": ' + _json_str(kind_config_short))
    if image_tarball_short_paths:
        fields.append(
            '  "image_tarballs": ' + _json_str_list(image_tarball_short_paths))
    if manifest_short_paths:
        fields.append(
            '  "manifest_files": ' + _json_str_list(manifest_short_paths))

    manifest_content = "{\n" + ",\n".join(fields) + "\n}\n"

    manifest_file = ctx.actions.declare_file(ctx.label.name + "_kind_manifest.json")
    ctx.actions.write(manifest_file, manifest_content)

    # Generate the wrapper script.
    cluster_name   = ctx.label.name
    launcher_short = ctx.file._launcher.short_path
    manifest_short = manifest_file.short_path
    workspace      = ctx.workspace_name

    wrapper_content = """\
#!/usr/bin/env bash
set -euo pipefail
RUNFILES_ROOT="${{TEST_SRCDIR:-${{RUNFILES_DIR:-}}}}"
if [[ -z "$RUNFILES_ROOT" ]]; then
  RUNFILES_ROOT="${{BASH_SOURCE[0]}}.runfiles"
fi
export RULES_KIND_MANIFEST="$RUNFILES_ROOT/{workspace}/{manifest_short}"
export RULES_KIND_CLUSTER_TARGET_NAME="{cluster_name}"
exec python3 "$RUNFILES_ROOT/{workspace}/{launcher_short}" "$@"
""".format(
        workspace      = workspace,
        manifest_short = manifest_short,
        launcher_short = launcher_short,
        cluster_name   = cluster_name,
    )

    wrapper = ctx.actions.declare_file(ctx.label.name + "_kind_cluster.sh")
    ctx.actions.write(wrapper, wrapper_content, is_executable = True)

    # Assemble runfiles.
    rf_files = [
        manifest_file,
        ctx.file._launcher,
        binary_info.kind,
        binary_info.kubectl,
    ]
    if ctx.file.config:
        rf_files.append(ctx.file.config)

    rf = ctx.runfiles(files = rf_files)

    # Add manifest YAML files.
    if ctx.files.manifests:
        rf = rf.merge(ctx.runfiles(files = ctx.files.manifests))

    # Add image tarballs.
    if ctx.files.images:
        rf = rf.merge(ctx.runfiles(files = ctx.files.images))

    return [DefaultInfo(
        executable = wrapper,
        runfiles   = rf,
    )]

kind_cluster = rule(
    doc = """\
Long-running kind (Kubernetes IN Docker) cluster for multi-service
integration tests via rules_itest.

Starts a kind cluster, pre-loads container images, applies Kubernetes
manifests, then writes $TEST_TMPDIR/<name>.env atomically and blocks
until SIGTERM. On SIGTERM, deletes the cluster.

Requires Docker to be available at test runtime. Must run outside the
Bazel linux-sandbox:
    tags = ["no-sandbox", "requires-docker"]

Use with rules_itest:
    itest_service(name = "k8s_svc", exe = ":my_cluster",
                  health_check = ":my_cluster_health")
""",
    implementation = _kind_cluster_impl,
    executable = True,
    attrs = {
        "k8s_version": attr.string(
            doc     = "Kubernetes minor version. Selects the kindest/node image tag.",
            default = "1.29",
        ),
        "config": attr.label(
            doc               = "Optional kind config YAML file (controls node count, port mappings, etc.).",
            allow_single_file = [".yaml", ".yml"],
        ),
        "images": attr.label_list(
            doc        = "Docker image tarballs to pre-load into the cluster via " +
                         "kind load image-archive. Each label must produce a " +
                         "single tarball file (e.g. rules_oci oci_tarball target).",
            allow_files = True,
        ),
        "manifests": attr.label_list(
            doc        = "YAML manifest files to apply with kubectl apply -f " +
                         "after the cluster is ready. Applied in listed order.",
            allow_files = [".yaml", ".yml"],
        ),
        "_binary": attr.label(
            doc       = "Platform-selected kind + kubectl binary.",
            default   = Label("//:kind_default"),
            providers = [KindBinaryInfo],
        ),
        "_launcher": attr.label(
            doc               = "The launcher.py script.",
            default           = Label("//private:launcher.py"),
            allow_single_file = True,
        ),
    },
)

# ---------------------------------------------------------------------------
# kind_health_check
# ---------------------------------------------------------------------------

def _kind_health_check_impl(ctx):
    cluster_name = ctx.attr.cluster.label.name
    env_file     = "${{TEST_TMPDIR}}/{}.env".format(cluster_name)

    script_content = """\
#!/usr/bin/env bash
set -euo pipefail
env_file="{env_file}"
if [[ -f "$env_file" ]]; then
    exit 0
fi
echo "[rules_kind] kind_cluster env file not yet present: $env_file" >&2
exit 1
""".format(env_file = env_file)

    script = ctx.actions.declare_file(ctx.label.name + "_health_check.sh")
    ctx.actions.write(script, script_content, is_executable = True)

    return [DefaultInfo(
        executable = script,
        runfiles   = ctx.runfiles(files = [script]),
    )]

kind_health_check = rule(
    doc = """\
Health-check binary for a kind_cluster target.

Exits 0 if and only if $TEST_TMPDIR/<cluster-name>.env exists (i.e. the
cluster is fully ready). Used as the health_check attribute of an
itest_service.
""",
    implementation = _kind_health_check_impl,
    executable = True,
    attrs = {
        "cluster": attr.label(
            doc       = "The kind_cluster target to check.",
            mandatory = True,
        ),
    },
)
