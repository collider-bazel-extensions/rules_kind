"""Analysis tests for kube_bench_test and KindClusterInfo (no cluster, no runtime)."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//:defs.bzl", "KindClusterInfo", "kind_cluster", "kube_bench_test")

def _config(env, target):
    """The decoded <name>.kube_bench.json the rule writes."""
    for action in analysistest.target_actions(env):
        outs = action.outputs.to_list()
        if action.mnemonic == "FileWrite" and outs and outs[0].basename.endswith(".kube_bench.json"):
            return json.decode(action.content)
    asserts.true(env, False, "no .kube_bench.json write action on " + str(target.label))
    return {}

# ---- config: benchmark, targets, ignore -----------------------------------------

def _config_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    cfg = _config(env, target)
    asserts.equals(env, ctx.attr.benchmark, cfg.get("benchmark"))
    asserts.equals(env, ctx.attr.benchmark_auto, cfg.get("benchmark_auto"))
    asserts.equals(env, ctx.attr.targets, cfg.get("targets"))
    asserts.equals(env, ctx.attr.k8s_version, cfg.get("k8s_version"))
    asserts.equals(env, "docker.io/aquasec/kube-bench:v0.16.0", cfg.get("image"))
    asserts.equals(env, ctx.attr.cluster, cfg.get("cluster"))
    asserts.true(env, cfg.get("launcher", "").endswith("tests/{}_kind_cluster.sh".format(ctx.attr.cluster)), cfg.get("launcher"))

    # The ignore file's validation action, only when there is an ignore file.
    validations = target[OutputGroupInfo]._validation.to_list()
    asserts.equals(env, 1 if ctx.attr.has_ignore else 0, len(validations))
    if ctx.attr.has_ignore:
        checks = [a for a in analysistest.target_actions(env) if a.mnemonic == "KubeBenchIgnoreCheck"]
        asserts.equals(env, 1, len(checks))
        asserts.true(env, "--check-ignore" in " ".join(checks[0].argv), str(checks[0].argv))

    # The runfiles carry the runner, the config and the cluster's launcher.
    runfiles = [f.short_path for f in target[DefaultInfo].default_runfiles.files.to_list()]
    asserts.true(env, "private/kube_bench.py" in runfiles, "runner missing from runfiles")
    asserts.true(env, "tests/{}_kind_cluster.sh".format(ctx.attr.cluster) in runfiles, "launcher missing from runfiles")
    return analysistest.end(env)

_config_test = analysistest.make(
    _config_test_impl,
    attrs = {
        "benchmark": attr.string(),
        "benchmark_auto": attr.bool(),
        "targets": attr.string_list(),
        "k8s_version": attr.string(),
        "cluster": attr.string(),
        "has_ignore": attr.bool(),
    },
)

# ---- analysis-time failures ------------------------------------------------------

def _failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

_failure_test = analysistest.make(
    _failure_test_impl,
    expect_failure = True,
    attrs = {"message": attr.string()},
)

# ---- KindClusterInfo ---------------------------------------------------------------

def _cluster_info_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    info = target[KindClusterInfo]
    asserts.equals(env, target.label.name, info.name)
    asserts.equals(env, "1.35", info.k8s_version)
    asserts.true(env, info.node_image.startswith("kindest/node:v1.35.8@sha256:"), info.node_image)
    asserts.equals(env, ["image.tar"], [f.basename for f in info.images.to_list()])
    asserts.equals(env, target[DefaultInfo].files_to_run.executable, info.launcher)
    return analysistest.end(env)

_cluster_info_test = analysistest.make(_cluster_info_test_impl)

def kube_bench_analysis_test_suite(name):
    """Declares the fixtures and analysis tests; `name` is a test_suite."""
    manual = ["manual", "no-sandbox", "requires-docker"]
    image = "//:kube_bench_image"

    kind_cluster(name = "kb_at_cluster_1_35", k8s_version = "1.35", images = [image], tags = manual)
    kind_cluster(name = "kb_at_cluster_1_29", k8s_version = "1.29", images = [image], tags = manual)
    kind_cluster(name = "kb_at_cluster_noimage", k8s_version = "1.35", tags = manual)

    kube_bench_test(
        name = "kb_at_auto_1_35",
        cluster = ":kb_at_cluster_1_35",
        ignore = "kube_bench/kind_ignore.yaml",
        tags = ["manual"],
    )
    _config_test(
        name = name + "_auto_1_35",
        target_under_test = ":kb_at_auto_1_35",
        benchmark = "cis-1.12",
        benchmark_auto = True,
        targets = ["master", "controlplane", "etcd", "node", "policies"],
        k8s_version = "1.35",
        cluster = "kb_at_cluster_1_35",
        has_ignore = True,
    )

    kube_bench_test(name = "kb_at_auto_1_29", cluster = ":kb_at_cluster_1_29", tags = ["manual"])
    _config_test(
        name = name + "_auto_1_29",
        target_under_test = ":kb_at_auto_1_29",
        benchmark = "cis-1.11",
        benchmark_auto = True,
        targets = ["master", "controlplane", "etcd", "node", "policies"],
        k8s_version = "1.29",
        cluster = "kb_at_cluster_1_29",
        has_ignore = False,
    )

    kube_bench_test(
        name = "kb_at_explicit",
        cluster = ":kb_at_cluster_1_35",
        benchmark = "cis-1.9",
        targets = ["node", "master"],
        tags = ["manual"],
    )
    _config_test(
        name = name + "_explicit",
        target_under_test = ":kb_at_explicit",
        benchmark = "cis-1.9",
        benchmark_auto = False,
        targets = ["master", "node"],  # kube-bench's order
        k8s_version = "1.35",
        cluster = "kb_at_cluster_1_35",
        has_ignore = False,
    )

    failures = {
        "missing_image": (
            {"cluster": ":kb_at_cluster_noimage"},
            "the kube-bench image is not loaded into",
        ),
        "bad_benchmark": (
            {"cluster": ":kb_at_cluster_1_35", "benchmark": "eks-1.2.0"},
            "unknown benchmark 'eks-1.2.0'",
        ),
        "bad_target": (
            {"cluster": ":kb_at_cluster_1_35", "targets": ["managedservices"]},
            "unknown target 'managedservices'",
        ),
        "duplicate_target": (
            {"cluster": ":kb_at_cluster_1_35", "targets": ["node", "node"]},
            "target 'node' is listed twice",
        ),
        "empty_targets": (
            {"cluster": ":kb_at_cluster_1_35", "targets": []},
            "targets is empty",
        ),
    }
    for case, (kwargs, message) in failures.items():
        kube_bench_test(name = "kb_at_" + case, tags = ["manual"], **kwargs)
        _failure_test(
            name = name + "_" + case,
            target_under_test = ":kb_at_" + case,
            message = message,
        )

    _cluster_info_test(name = name + "_cluster_info", target_under_test = ":kb_at_cluster_1_35")

    native.test_suite(
        name = name,
        tests = [
            name + "_auto_1_35",
            name + "_auto_1_29",
            name + "_explicit",
            name + "_cluster_info",
        ] + [name + "_" + case for case in failures],
    )
