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
    write env file → wait (SIGTERM / parent exit)
    SIGTERM → kind delete cluster   (reaper deletes it if the launcher dies)
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

SHA-256 checksums are stored in `_KIND_VERSIONS` in `extensions.bzl`. They are
the published release sums (kind `<asset>.sha256sum` on the GitHub release,
kubectl `<url>.sha256` on dl.k8s.io), regenerated and cross-checked against the
downloaded binaries by `tools/update_checksums.sh`. `//tests:checksums_test`
fails on an empty or malformed value, and `_kind_binary_repo` fails on an empty
one at fetch time.

rules_kind's own `MODULE.bazel` registers `kind.version(["1.35", "1.36",
"1.37"])` (pinned kind v0.33.0 downloads) and `kind.system(["1.29", "1.32"])`,
so a consumer that declares no tag gets hermetic binaries for the supported
minors and host binaries for the EOL ones. The new minors are not system-mode:
their node images are built for kind v0.33.0 and a host kind of another version
is not a safe stand-in. Each `kind_<ver>_<platform>`
repo is declared once: the extension visits the root module first, so a
consumer's `kind.version(["1.29"])` replaces the system repos for 1.29 (since
v0.1.5; earlier versions failed on the duplicate repo name).

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

kind requires Docker or podman **at test execution time**, not at build/analysis time. `bazel build //...` and `bazel test //... --test_tag_filters=-manual` succeed on Docker-less hosts; only a target that actually runs (e.g. `bazel test //my:kind_test`) trips the runtime probe.

Pre-v0.1.4 the repo rule probed at analysis time via `_check_container_runtime`, which contaminated wildcard analysis on Docker-less hosts — tag filtering happens after analysis, so the analysis-time `fail()` bypassed the filter. v0.1.4 removed the analysis-time probe entirely; the launcher's existing execution-time probe is the single source of truth. Closes #6.

### Runtime detection

The launcher tries runtimes in order:

1. **Docker** — `docker info` succeeds → use Docker directly.
2. **podman** — `podman --runtime /usr/bin/crun info` succeeds → use podman
   with `KIND_EXPERIMENTAL_PROVIDER=podman`.
3. **Error** — neither available; fail with a clear install hint.

### Podman image store

Bazel's test runner sets `HOME=$TEST_TMPDIR`, and rootless podman keeps its
image store under `$XDG_DATA_HOME` (default `$HOME/.local/share`). Before
v0.2.1 every test run therefore got a fresh store inside the execroot: the
~1 GB `kindest/node` image was pulled again each time, and the store's
subuid-owned files made the next build in that output base fail ("Failed to
prepare the symlink forest ... Operation not permitted"). The launcher now
sets `XDG_DATA_HOME` / `XDG_CONFIG_HOME` (if unset) to the passwd home's
`.local/share` / `.config` before probing for a runtime. kind and kubectl
read `$HOME/.kube`, not these, so the kubeconfig stays in the test's tmpdir
and `~/.kube/config` is never touched.

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
2. kind create cluster --name <name> [--config <config_file>] [--image <digest-pinned kindest/node image for k8s_version>]
3. kind get kubeconfig --name <name> > $TEST_TMPDIR/kubeconfig
4. Poll kubectl cluster-info until API server responds (max 120 s)
5. For each image in images[]:
       kind load docker-image <image> --name <name>
6. For each file in manifest_files[]:
       kubectl apply -f <file> --kubeconfig $TEST_TMPDIR/kubeconfig
7. Write $TEST_TMPDIR/<target_name>.env atomically (temp file + os.replace)
8. Wait, checking once a second that the parent process is still alive
```

Before step 2 the launcher installs its SIGTERM + SIGINT handlers and, unless
`RULES_KIND_KEEP_CLUSTER` is set, starts the reaper (see Shutdown).

### Shutdown

```
SIGTERM / SIGINT received, or parent pid changed
  ↓
kind delete cluster --name <name>
  ↓
tell the reaper teardown is done
  ↓
exit(0)
```

`kind delete cluster` removes all Docker containers, networks, and volumes
created for the cluster. No cleanup is left to Bazel.

Signals alone are not enough (#9):

- **rules_itest does not stop services on test failure.** In one-shot mode
  `svcinit` calls `os.Exit(1)` when the test fails, without signalling its
  services. Services run in their own process group, so the launcher is
  orphaned rather than killed. The launcher records its parent pid at startup
  and tears down when it changes.
- **rules_itest SIGKILLs the process group after `shutdown_timeout`** (default
  1 s), which can interrupt `kind delete cluster`.

### Reaper

When a test exits, Bazel kills every process it left behind, including ones
in their own session (verified: a `start_new_session=True` child of an
`sh_test` dies when the test returns). rules_itest's usual teardown is
SIGTERM, then SIGKILL of the launcher's process group one second later,
then exit, so the reaper runs exactly when Bazel is about to kill it. It
must therefore not be one of the test's processes.

**systemd user unit (preferred).** Before creating the cluster, the launcher
runs `systemd-run --user --collect --unit rules-kind-reaper-<name>
--property=Delegate=yes -- python3 launcher.py --reap-pid <kind> <name>
<pid> <starttime> <log>`. systemd, not the test, is the reaper's parent. The
launcher's environment is passed through with `--setenv=NAME` (a service
otherwise gets the user manager's environment). The reaper polls
`/proc/<pid>/stat` once a second; pid plus start time (field 22) identifies
the launcher even if the pid is reused. When the launcher is gone it runs
`kind delete cluster`, which is harmless if the cluster is already gone.
After a finished teardown the launcher runs `systemctl --user stop
--no-block` on the unit, so the usual case doesn't run a second delete.

**Child process (fallback).** If `systemd-run --user` fails (no user
manager, no D-Bus), the launcher starts `launcher.py --reap <kind> <name>`
with `start_new_session=True`, so signals sent to the launcher's process
group don't reach it. The reaper blocks reading its stdin, a pipe whose write
end only the launcher holds. After deleting the cluster the launcher writes
`done` and closes the pipe; the reaper then exits. If the launcher dies first
(any signal, any crash), the reaper reads EOF without `done` and runs `kind
delete cluster` itself. This covers launcher deaths while the test runs
(`cluster_cleanup_test`), not a launcher killed as the test exits.

Before v0.2.1 the child process was the only reaper, and clusters whose
launcher was SIGKILLed during rules_itest's shutdown were left stuck in
"Stopping". `reaper_outlives_test` reproduces that case; CI's "No kind
clusters left behind" step checks the outcome after `bazel test` returns.

Output goes to `$TEST_TMPDIR/<target>.reaper.log` in both modes.

`RULES_KIND_KEEP_CLUSTER=1` disables both the launcher's deletion and the
reaper, and logs the command to delete the cluster by hand.

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
| `k8s_version` | string      | `"1.35"`  | Kubernetes minor version. Selects the digest-pinned `kindest/node` image and the kind+kubectl binary pair. Supported: `"1.35"`, `"1.36"`, `"1.37"`; EOL but kept: `"1.32"`, `"1.29"`. |
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
  "k8s_version":   "1.35",
  "node_image":    "kindest/node:v1.35.8@sha256:07b2…",
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
kind_cluster(name = "k8s", k8s_version = "1.35", images = [":app_image"])
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
  kind clusters left when the reaper itself could not run (host reboot,
  container runtime down at teardown).
- **Local registry**: optional `kind_registry` rule that starts a local Docker
  registry inside the kind cluster, eliminating the need to `kind load` large
  images.
- **Multi-node clusters**: first-class `node_count` attribute as a shorthand
  for the common case (without requiring a full kind config file).

---

## Vendored test images

`tests/testdata/busybox.tar` is a hand-fetched `docker save`-format archive of `docker.io/library/busybox:stable` for `linux/amd64`, produced via `tools/fetch_busybox.sh` at maintainer time. The in-tree `cluster_test` fixture passes it via `kind_cluster.images = [...]` so the cluster preloads the image at boot; the pod then references `busybox:stable` with `--image-pull-policy=Never` and uses the preloaded copy — no runtime registry pull.

**Why vendored** (vs. rules_oci's `oci_pull` + `oci_tarball`): for a single small test fixture, the rules_oci dep tree is heavyweight (rules_python, OCI lockfile, etc.). The 5MB committed tarball is permanent test infrastructure; the maintainer-rerun-when-stale flow matches `tools/render_*.sh` patterns elsewhere in the family. If rules_kind ever needs a second test image, that calculus tips toward rules_oci.

**Why preload at all** (vs. let kind pull at runtime): rootless-podman in CI can't resolve `registry-1.docker.io` from inside the kind node's pod network — DNS lookups time out against the slirp4netns/pasta NAT. Issue #5 has the full reproducer. Preloading sidesteps the resolver entirely (and is faster on the docker path too).

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
- **Orphaned clusters when the reaper cannot run.** The reaper covers launcher
  crashes and kills, but not a host reboot or a container runtime that is down
  at teardown, and without a systemd user instance it doesn't survive the end
  of the test (see Reaper). The `kind_cleanup` tool (Phase 2) will address
  this.
- **Target name collision.** Two `kind_cluster` targets with the same local
  name in different packages write to the same env file path.
- **Windows not supported** (no pre-built binary source; PRs welcome).
