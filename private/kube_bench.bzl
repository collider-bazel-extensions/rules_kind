"""kube_bench_test: kube-bench (CIS Kubernetes Benchmark) against a kind_cluster."""

load(":cluster.bzl", "KindClusterInfo")
load(
    ":kube_bench_versions.bzl",
    "KUBE_BENCH",
    "KUBE_BENCH_AUTO_BENCHMARK",
    "KUBE_BENCH_CIS_BENCHMARKS",
    "KUBE_BENCH_IMAGE_REF",
    "KUBE_BENCH_TARGETS",
)

def _rlocation(ctx, f):
    """The runfiles path of f (`<repo>/<path>`), for the runner and wrapper."""
    if f.short_path.startswith("../"):
        return f.short_path[3:]
    return ctx.workspace_name + "/" + f.short_path

def _label_str(label):
    s = str(label)
    return s[2:] if s.startswith("@@//") else s

def resolve_benchmark(benchmark, k8s_version):
    """-> (benchmark, error). benchmark = "auto" picks the table entry."""
    if benchmark == "auto":
        b = KUBE_BENCH_AUTO_BENCHMARK.get(k8s_version)
        if not b:
            return None, "no CIS benchmark known for k8s_version {}; set benchmark (one of: {})".format(
                k8s_version,
                ", ".join(KUBE_BENCH_CIS_BENCHMARKS),
            )
        return b, None
    if benchmark not in KUBE_BENCH_CIS_BENCHMARKS:
        return None, "unknown benchmark '{}': kube-bench {} has the generic CIS benchmarks {} (or use \"auto\")".format(
            benchmark,
            KUBE_BENCH["version"],
            ", ".join(KUBE_BENCH_CIS_BENCHMARKS),
        )
    return benchmark, None

def _kube_bench_test_impl(ctx):
    cluster = ctx.attr.cluster[KindClusterInfo]
    where = "kube_bench_test {}".format(_label_str(ctx.label))

    # The image must be one the cluster loads at boot: the Job can't pull.
    image = ctx.file._image
    if image.path not in [f.path for f in cluster.images.to_list()]:
        fail(("{}: the kube-bench image is not loaded into {}. Add it to the " +
              "kind_cluster's images:\n    images = [..., \"@rules_kind//:kube_bench_image\"],").format(
            where,
            _label_str(ctx.attr.cluster.label),
        ))

    benchmark, err = resolve_benchmark(ctx.attr.benchmark, cluster.k8s_version)
    if err:
        fail("{}: {}".format(where, err))

    targets = ctx.attr.targets
    if not targets:
        fail("{}: targets is empty (known: {})".format(where, ", ".join(KUBE_BENCH_TARGETS)))
    seen = {}
    for t in targets:
        if t not in KUBE_BENCH_TARGETS:
            fail("{}: unknown target '{}' (known: {})".format(where, t, ", ".join(KUBE_BENCH_TARGETS)))
        if t in seen:
            fail("{}: target '{}' is listed twice".format(where, t))
        seen[t] = True

    runner = ctx.file._runner
    ignore = ctx.file.ignore

    config = {
        "label": _label_str(ctx.label),
        "cluster": cluster.name,
        "cluster_label": _label_str(ctx.attr.cluster.label),
        "launcher": _rlocation(ctx, cluster.launcher),
        "k8s_version": cluster.k8s_version,
        "benchmark": benchmark,
        "benchmark_auto": ctx.attr.benchmark == "auto",
        "targets": [t for t in KUBE_BENCH_TARGETS if t in targets],
        "ignore": _rlocation(ctx, ignore) if ignore else None,
        "ignore_shown": ignore.short_path if ignore else None,
        "fail_on_stale": ctx.attr.fail_on_stale,
        "image": KUBE_BENCH_IMAGE_REF,
        "kube_bench_version": KUBE_BENCH["version"],
        "job_timeout_s": ctx.attr.job_timeout,
    }
    config_file = ctx.actions.declare_file(ctx.label.name + ".kube_bench.json")
    ctx.actions.write(config_file, json.encode_indent(config) + "\n")

    wrapper = ctx.actions.declare_file(ctx.label.name + ".kube_bench_test.sh")
    ctx.actions.write(wrapper, """\
#!/usr/bin/env bash
set -euo pipefail
RUNFILES_ROOT="${{TEST_SRCDIR:-${{RUNFILES_DIR:-}}}}"
if [[ -z "$RUNFILES_ROOT" || ! -e "$RUNFILES_ROOT/{runner}" ]]; then
  RUNFILES_ROOT="${{BASH_SOURCE[0]}}.runfiles"
fi
export RUNFILES_DIR="$RUNFILES_ROOT"
exec python3 "$RUNFILES_ROOT/{runner}" --run "$RUNFILES_ROOT/{config}" "$@"
""".format(
        runner = _rlocation(ctx, runner),
        config = _rlocation(ctx, config_file),
    ), is_executable = True)

    files = [runner, config_file]
    if ignore:
        files.append(ignore)
    runfiles = ctx.runfiles(files = files).merge(ctx.attr.cluster[DefaultInfo].default_runfiles)

    # Build-time check of the ignore file's shape (not its expiry dates: the
    # date isn't an input, so a cached result can't depend on it; the test
    # checks expiry when it runs).
    validations = []
    if ignore:
        stamp = ctx.actions.declare_file(ctx.label.name + ".kube_bench_ignore.ok")
        ctx.actions.run_shell(
            inputs = [runner, ignore],
            outputs = [stamp],
            command = 'python3 "$1" --check-ignore "$2" --shown "$3" --stamp "$4"',
            arguments = [runner.path, ignore.path, ignore.short_path, stamp.path],
            use_default_shell_env = True,
            mnemonic = "KubeBenchIgnoreCheck",
            progress_message = "Checking kube-bench ignore file " + ignore.short_path,
        )
        validations.append(stamp)

    return [
        DefaultInfo(executable = wrapper, runfiles = runfiles),
        OutputGroupInfo(_validation = depset(validations)),
    ]

_kube_bench_test = rule(
    doc = "Internal rule; use the kube_bench_test macro from defs.bzl.",
    implementation = _kube_bench_test_impl,
    test = True,
    attrs = {
        "cluster": attr.label(
            doc = "The kind_cluster to check. Its images must include @rules_kind//:kube_bench_image.",
            mandatory = True,
            providers = [KindClusterInfo],
        ),
        "benchmark": attr.string(
            doc = "CIS benchmark (e.g. \"cis-1.12\"), or \"auto\" to pick it from the cluster's k8s_version.",
            default = "auto",
        ),
        "targets": attr.string_list(
            doc = "kube-bench targets run on control-plane nodes; worker nodes run `node` if listed.",
            default = KUBE_BENCH_TARGETS,
        ),
        "ignore": attr.label(
            doc = "YAML ignore file: `checks:` entries with id, reason and optional expires.",
            allow_single_file = [".yaml", ".yml"],
        ),
        "fail_on_stale": attr.bool(
            doc = "Fail when an ignore entry's check did not FAIL on any node.",
            default = False,
        ),
        "job_timeout": attr.int(
            doc = "Seconds to wait for the kube-bench Jobs to finish.",
            default = 300,
        ),
        "_image": attr.label(
            default = Label("//:kube_bench_image"),
            allow_single_file = True,
        ),
        "_runner": attr.label(
            default = Label("//private:kube_bench.py"),
            allow_single_file = True,
        ),
    },
)

def kube_bench_test(name, cluster, benchmark = "auto", targets = None, ignore = None, fail_on_stale = False, job_timeout = 300, tags = [], size = "large", timeout = "long", **kwargs):
    """Runs kube-bench (CIS Kubernetes Benchmark) on every node of a kind_cluster.

    Fails on any FAIL result whose check id is not in `ignore`, and on any
    expired ignore entry. See README.md, "kube_bench_test".

    Standalone, the test starts `cluster` itself and deletes it afterwards. As
    the `test` of a rules_itest `service_test` whose services include the
    cluster, it uses that cluster (its env file already exists).

    Args:
      name: test name.
      cluster: kind_cluster target; its images must include
        "@rules_kind//:kube_bench_image".
      benchmark: "auto" (from the cluster's k8s_version) or a CIS benchmark
        in the pinned kube-bench image, e.g. "cis-1.12".
      targets: kube-bench targets for control-plane nodes (default: master,
        controlplane, etcd, node, policies). Worker nodes run "node" if it
        is listed.
      ignore: YAML ignore file (see README).
      fail_on_stale: also fail on ignore entries whose check didn't FAIL.
      job_timeout: seconds to wait for the kube-bench Jobs.
      tags: test tags; "no-sandbox" and "requires-docker" are added.
      size: test size (default "large").
      timeout: test timeout (default "long").
      **kwargs: passed to the test rule.
    """
    tags = list(tags)
    for t in ["no-sandbox", "requires-docker"]:
        if t not in tags:
            tags.append(t)
    _kube_bench_test(
        name = name,
        cluster = cluster,
        benchmark = benchmark,
        targets = targets if targets != None else KUBE_BENCH_TARGETS,
        ignore = ignore,
        fail_on_stale = fail_on_stale,
        job_timeout = job_timeout,
        tags = tags,
        size = size,
        timeout = timeout,
        **kwargs
    )
