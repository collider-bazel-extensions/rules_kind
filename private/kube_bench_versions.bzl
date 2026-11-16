"""The pinned kube-bench image and the CIS benchmarks it carries.

Shared by extensions.bzl (which fetches the image) and kube_bench.bzl (which
runs it). Re-pin with tools/update_kube_bench.sh.
"""

# kube-bench v0.16.0 (2026-08-05), Docker Hub `aquasec/kube-bench:v0.16.0`.
# `index_digest` is the multi-arch OCI image index; `manifests` are the
# per-platform image manifests it lists (checked against the fetched index).
KUBE_BENCH = {
    "version": "0.16.0",
    "repository": "aquasec/kube-bench",
    "tag": "v0.16.0",
    "index_digest": "sha256:75506f222d1eb6ce2a751a5533bdc0a3b54c898e2e49e7751d0ee22cfb862679",
    "manifests": {
        "linux_amd64": "sha256:d2e6f685f16cf71228630305d7d69b1fe0c6cbf42a3275cdfc8a55f5f925bbee",
        "linux_arm64": "sha256:2048e9b04537706e57a25bca4f39bab86e347aec9cf1d7a86071a289cd240777",
    },
}

# The name the image is loaded under (the RepoTags of the docker-archive
# rules_kind builds). The Job uses it with `imagePullPolicy: Never`.
KUBE_BENCH_IMAGE_REF = "docker.io/{}:{}".format(KUBE_BENCH["repository"], KUBE_BENCH["tag"])

KUBE_BENCH_PLATFORMS = ["linux_amd64", "linux_arm64"]

# Registries tried in order, each by digest. mirror.gcr.io (Google's Docker
# Hub cache) serves anonymous pulls without Docker Hub's rate limit;
# registry-1.docker.io is the source of truth.
KUBE_BENCH_REGISTRIES = ["mirror.gcr.io", "registry-1.docker.io"]

# The generic CIS benchmarks in the pinned image's cfg/ directory
# (distribution-specific ones -- eks, gke, aks, k3s, rke, rh, ... -- don't
# describe a kind cluster and are not accepted).
KUBE_BENCH_CIS_BENCHMARKS = [
    "cis-1.5",
    "cis-1.6",
    "cis-1.20",
    "cis-1.23",
    "cis-1.24",
    "cis-1.7",
    "cis-1.8",
    "cis-1.9",
    "cis-1.10",
    "cis-1.11",
    "cis-1.12",
]

# benchmark = "auto": the CIS benchmark for each k8s_version rules_kind
# supports. 1.29 and 1.32 follow kube-bench's own version_mapping. CIS has
# published nothing newer than Kubernetes Benchmark v1.12 (k8s 1.32-1.34) in
# kube-bench v0.16.0, so 1.35-1.37 use cis-1.12, the same benchmark
# kube-bench's own auto-detection picks for them.
KUBE_BENCH_AUTO_BENCHMARK = {
    "1.29": "cis-1.11",
    "1.32": "cis-1.12",
    "1.35": "cis-1.12",
    "1.36": "cis-1.12",
    "1.37": "cis-1.12",
}

# kube-bench --targets for the generic CIS benchmarks, in kube-bench's order.
KUBE_BENCH_TARGETS = ["master", "controlplane", "etcd", "node", "policies"]
