# rules_kind — Design Document

## Goals

`rules_kind` provides full Kubernetes clusters for Bazel integration tests
using [kind](https://kind.sigs.k8s.io) (Kubernetes IN Docker). The design is
driven by three constraints:

1. **Real pods.** Tests that require actual container execution — running
   processes, HTTP probes, volume mounts, init containers — cannot use
   `rules_kubernetes`. kind runs a complete kubelet + container runtime.
2. **rules_itest first.** kind clusters take 30–90 s to start. Per-test
   isolation is not viable. All usage goes through
   [rules_itest](https://github.com/dzbarsky/rules_itest) for shared-cluster,
   multi-service integration tests.
3. **Consistent env-file contract.** The `$TEST_TMPDIR/<name>.env` readiness
   protocol from `rules_pg` and `rules_kubernetes` is preserved. Tests that
   already source an env file require no changes.

---

## Relationship to `rules_kubernetes`

These two packages are complementary tiers, not competing alternatives:

| | `rules_kubernetes` | `rules_kind` |
|---|---|---|
| Backend | kube-apiserver + etcd | kind (Docker) |
| Docker required | No | Yes |
| Real pods | No | Yes |
| Startup time | ~5 s | ~30–90 s |
| Per-test isolation | Yes (`kubernetes_test`) | No |
| `rules_itest` | Optional | Required |
| Best for | Controller unit/integration tests | End-to-end tests with running containers |

The intended progression: write controller logic tests with `rules_kubernetes`,
write end-to-end tests with `rules_kind`.

---

## Scope

`rules_kind` targets end-to-end integration tests where:

- The system under test includes one or more container images.
- Test assertions depend on running processes inside pods (HTTP endpoints,
  file output, subprocess exit codes).
- Multiple services interact (API server + database + worker + Kubernetes
  operator).

It does **not** replace `rules_kubernetes` for controller unit tests. Running
kind for a test that only exercises `client-go` API calls adds 60 s of overhead
for no benefit.

### What you can test

- Full operator lifecycle: deploy operator image, apply CRD, create CR,
  observe reconciliation via pod logs or HTTP endpoints.
- Services that run inside pods: HTTP APIs, background workers, sidecar
  containers.
- Init container sequencing and volume data flow.
- Readiness/liveness probe behavior.
- Node affinity, taints, tolerations, and real scheduling decisions.
- Network policy enforcement (with a CNI plugin installed in the kind cluster).

### What you cannot test

- Multi-node behaviour that requires real hardware (NUMA, SR-IOV, GPUs).
- Production network topology (kind uses a bridge network internal to Docker).
- Performance benchmarks (Docker adds overhead; nodes share the host kernel).

---

## High-level architecture

```
MODULE.bazel / WORKSPACE
        │
        ▼
  extensions.bzl / repositories.bzl     ← fetch or symlink kind + kubectl
        │
        ▼
  KindBinaryInfo  (private/binary.bzl)  ← platform-agnostic binary target
        │                                   carries kind + kubectl paths
        ▼
  kind_cluster rule  (private/cluster.bzl)
    generates JSON manifest + shell wrapper
        │
        ▼
  launcher.py
    kind create cluster
    kind load docker-image (images)
    kubectl apply (manifests)
    write env file → signal.pause()
    SIGTERM → kind delete cluster
        │
        ▼
  kind_health_check  (private/cluster.bzl)
    file-exists health probe
```

---

## Binary acquisition

Two binaries are required: `kind` and `kubectl`. Both are single files (not
tarballs) downloaded directly from GitHub / dl.k8s.io.

### Downloaded binaries (`kind.version()`)

`_kind_binary_repo` calls `rctx.download()` (not `download_and_extract`) to
fetch the two binaries and mark them executable:

```
kind:    https://github.com/kubernetes-sigs/kind/releases/download/
             v{kind_version}/kind-{os}-{arch}
kubectl: https://dl.k8s.io/release/v{k8s_version}/bin/{os}/{arch}/kubectl
```

SHA-256 checksums are stored in `_KIND_VERSIONS` in `extensions.bzl`.

### System binaries (`kind.system()`)

`_kind_system_binary_repo` symlinks host-installed binaries. Auto-detection:

1. `command -v kind` / `command -v kubectl` — PATH lookup.
2. Common locations: `/usr/local/bin`, `/usr/bin`, `$HOME/.local/bin`.

If kind cannot be found, the build fails immediately with a clear error and a
suggested install command (`brew install kind` / `apt install kind`).

Both modes produce a repo named `kind_<k8s_version>_<platform>` (e.g.,
`kind_1_29_linux_amd64`) exposing `kind` and `kubectl` as runfiles.

---

## Container runtime dependency

kind requires Docker or podman. The launcher auto-detects which is available.

### Runtime detection

The launcher tries runtimes in order:

1. **Docker** — `docker info` succeeds → use Docker directly.
2. **podman** — `podman --runtime /usr/bin/crun info` succeeds → use podman
   with `KIND_EXPERIMENTAL_PROVIDER=podman`.
3. **Error** — neither available; fail with a clear install hint.

### Sandbox bypass

Bazel's linux-sandbox blocks access to `/var/run/docker.sock` (Docker) and
prevents the cgroup manipulation that rootless podman needs. `kind_cluster`
targets must be tagged to run outside the sandbox:

```python
kind_cluster(
    name = "k8s",
    tags = ["no-sandbox", "requires-docker"],
    ...
)
```

Or globally:

```
# .bazelrc
test:kind --strategy=TestRunner=local
```

### Rootless podman and cgroup delegation

Rootless podman requires a systemd scope with `Delegate=yes` so the kubelet
inside the kind node can manage cgroups. The launcher detects when it is
running under podman and not already in a delegated scope (checked via
`$INVOCATION_ID`) and re-executes itself via:

```sh
systemd-run --scope --user --property=Delegate=yes -- python3 launcher.py ...
```

`XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS` are populated automatically
from `/run/user/<uid>/` when the Bazel sandbox strips them.

### CI requirements

CI runners must have Docker or podman available. GitHub Actions `ubuntu-latest`,
`ubuntu-22.04`, and `ubuntu-24.04` all have Docker. macOS runners require
Docker Desktop or Colima. Systems with rootless podman (Fedora, RHEL 8+) work
with the automatic systemd-run re-execution.

---

## Cluster lifecycle

### Startup

```
1. Generate cluster name: kind-<uuid[:12]>
2. kind create cluster --name <name> [--config <config_file>] [--image kindest/node:v{k8s_version}]
3. kind get kubeconfig --name <name> > $TEST_TMPDIR/kubeconfig
4. Poll kubectl cluster-info until API server responds (max 120 s)
5. For each image in images[]:
       kind load docker-image <image> --name <name>
6. For each file in manifest_files[]:
       kubectl apply -f <file> --kubeconfig $TEST_TMPDIR/kubeconfig
7. Write $TEST_TMPDIR/<target_name>.env atomically (temp file + os.replace)
8. Install SIGTERM + SIGINT handlers
9. signal.pause()
```

### Shutdown

```
SIGTERM received
  ↓
kind delete cluster --name <name>
  ↓
exit(0)
```

`kind delete cluster` removes all Docker containers, networks, and volumes
created for the cluster. No cleanup is left to Bazel.

### Crash recovery

If the launcher crashes before deleting the cluster, Docker containers are
left running. The cluster name includes a UUID so there is no naming collision
with subsequent runs. A `bazel run //tools:kind_cleanup` helper (Phase 2) will
prune orphaned clusters.

---

## Env file format

Written atomically to `$TEST_TMPDIR/<target_name>.env` once the cluster is
fully ready:

```
KUBECONFIG=/tmp/.../kubeconfig
KIND_CLUSTER_NAME=kind-abc123def456
KUBE_API_SERVER=https://127.0.0.1:6443
KUBECTL=/path/to/kubectl
```

Tests source this file:

```bash
source "$TEST_TMPDIR/k8s.env"
"$KUBECTL" get pods --all-namespaces --kubeconfig "$KUBECONFIG"
```

---

## `kind_health_check`

Exits 0 iff `$TEST_TMPDIR/<cluster_target_name>.env` exists. Identical
protocol to `pg_health_check` and `kubernetes_health_check`.

---

## `kind_cluster` attributes

| Attribute    | Type         | Default   | Description |
|---|---|---|---|
| `k8s_version` | string      | `"1.29"`  | Kubernetes minor version. Selects the `kindest/node` image and the kind+kubectl binary pair. Supported: `"1.29"`, `"1.32"`. v0.1.2 added `"1.32"` because `kindest/node:v1.32.2` ships runc 1.2.5, which fixes a bind-mount-remount-RO EPERM bug under rootless container engines + kernel 6.x that breaks workloads such as `kube-proxy` and Cilium's agent on the older 1.29.2 image (runc 1.1.12). |
| `config`      | label        | `None`    | kind config YAML file. Controls node count, port mappings, feature gates. |
| `images`      | label\_list  | `[]`      | Container image targets to pre-load into the cluster via `kind load docker-image`. |
| `manifests`   | label        | `None`    | `kubernetes_manifest` target applied after the cluster is ready. |

---

## Image loading

Container images declared in `images` must be Bazel targets that produce a
Docker tarball (e.g., `rules_oci` `oci_tarball`, or `rules_docker`
`container_image`). The launcher loads each image via:

```
kind load docker-image <image_name> --name <cluster_name>
```

Images are identified by their `RepoTags` field in the tarball manifest. The
Bazel target must produce a single image with a deterministic tag (e.g.,
`myapp/server:test`).

Loading is sequential. For clusters with many large images, consider using a
custom kind config with `containerdConfigPatches` to pull from a local registry
instead.

---

## Combined launcher manifest

`kind_cluster` generates a JSON manifest at build time:

```json
{
  "workspace":      "<workspace_name>",
  "kind_bin":       "<runfile path>",
  "kubectl_bin":    "<runfile path>",
  "k8s_version":   "1.29",
  "kind_config":    "<runfile path>",
  "images":         ["myapp/server:test", "myapp/worker:test"],
  "manifest_files": ["config/crd/foo.yaml", "config/rbac/role.yaml"]
}
```

`kind_config`, `images`, and `manifest_files` are omitted when not provided.

---

## rules_itest integration

`kind_cluster` and `kind_health_check` slot directly into rules_itest:

```python
kind_cluster(name = "k8s", k8s_version = "1.29", images = [":app_image"])
kind_health_check(name = "k8s_health", cluster = ":k8s")

itest_service(name = "k8s_svc", exe = ":k8s", health_check = ":k8s_health")

itest_service(
    name    = "app_svc",
    exe     = "//cmd/app",
    deps    = [":k8s_svc"],
    http_health_check_address = "http://127.0.0.1:${PORT}/healthz",
    autoassign_port = True,
)

service_test(
    name     = "e2e_test",
    test     = ":e2e_test_bin",
    services = [":k8s_svc", ":app_svc"],
)
```

### Lifecycle under rules_itest

```
rules_itest service manager
  ├── starts :k8s_svc     (kind create → load images → apply manifests → write env file)
  │     polls :k8s_health (exits 0 when env file exists)
  ├── starts :app_svc     (your application, reads KUBECONFIG from env file)
  │     polls /healthz
  └── runs :e2e_test_bin  (sources env file, hits HTTP API, checks pod status)
  └── sends SIGTERM
        :k8s_svc → kind delete cluster
        :app_svc → your shutdown handler
```

---

## Analysis-time validation

`kind_cluster` validates at Bazel analysis time:
- `k8s_version` must be a known version string.
- `config` must be a single `.yaml` file.

Failures surface as `bazel build` errors, not as runtime failures.

---

## Phase 2

- **`kind_cleanup` tool**: `bazel run //tools:kind_cleanup` prunes orphaned
  kind clusters (those with the `rules-kind` label) left by crashed launchers.
- **Local registry**: optional `kind_registry` rule that starts a local Docker
  registry inside the kind cluster, eliminating the need to `kind load` large
  images.
- **Multi-node clusters**: first-class `node_count` attribute as a shorthand
  for the common case (without requiring a full kind config file).

---

## Known limitations and non-goals

- **Docker or podman required.** Tests must run with `tags = ["no-sandbox"]`
  or `--strategy=TestRunner=local`. See _Container runtime dependency_ above.
  Rootless podman requires a delegated systemd scope; the launcher handles this
  automatically.
- **Startup time ~30–90 s.** Not suitable for per-test isolation or fast
  feedback loops. Use `rules_kubernetes` for controller unit tests.
- **No `kind_test` macro.** All usage requires `rules_itest`.
- **Image loading is sequential and slow for large images.** Consider a local
  registry for images larger than ~200 MB.
- **Orphaned clusters on launcher crash.** The `kind_cleanup` tool (Phase 2)
  will address this.
- **Target name collision.** Two `kind_cluster` targets with the same local
  name in different packages write to the same env file path.
- **Windows not supported** (no pre-built binary source; PRs welcome).
