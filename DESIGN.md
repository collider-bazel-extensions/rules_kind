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
1. Generate cluster name: kind-<uuid[:12]>; log to ~/.local/state/rules_kind/<name>.log
   Sweep stale clusters (see Ownership records and sweep)
   Take a cluster slot; optionally wait for RULES_KIND_MIN_FREE_MB (see Admission)
   Write the ownership record; start the reaper
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
`RULES_KIND_KEEP_CLUSTER` is set, writes the ownership record and starts the
reaper (see Shutdown). A signal while waiting for a slot ends the launcher
with nothing to clean up: no record or cluster exists yet.

### Shutdown

```
SIGTERM / SIGINT received, or parent pid changed
  ↓
kind delete cluster --name <name>       (600 s timeout)
  ↓
confirm: `kind get clusters` doesn't list it and no container has its label
  ↓ confirmed                          ↓ not confirmed
remove the record, release the reaper, leave the reaper running; it retries
remove the log                         once the launcher has exited
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
- **`kind delete` can fail or be cut short and leave stopped nodes** that
  kind still lists (`Exited (137)`), on a loaded host especially (#14).
  Before v0.3.0 the launcher released the reaper after any delete attempt, so
  nothing retried. Now only a confirmed deletion releases it.
- **The launcher's stdout can be a closed pipe** by the time it tears down
  (rules_itest has exited). `_log` catches `BrokenPipeError` and points stdout
  at `/dev/null`, so the teardown still reaches `kind delete` (#12).

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
`kind delete cluster` and checks the result like the launcher does,
retrying with backoff (5 s doubling to 60 s) for up to 30 minutes; after that
the record stays for the next launcher's sweep. After a confirmed teardown
the launcher runs `systemctl --user stop --no-block` on the unit, so the
usual case doesn't run a second delete.

**The unit's access to the runtime (v0.3.1, #17).** A user service runs
with the *user manager's* credentials, not the test's. Supplementary groups
are fixed when `systemd --user` starts, so a user who joined `docker` later
has the group in their shells and tests but not in their units, until they
log out completely. The test then creates clusters fine, but every reaper
`kind delete` fails with "permission denied" on `/var/run/docker.sock`, and
killed tests leak clusters. So before relying on a unit the launcher probes
one: `systemd-run --user --wait --pipe -- sh -c '<runtime> info …; echo
<status>'`, with the same `--setenv` environment. Then:
- **It reaches the runtime:** the reaper unit is used as is.
- **It doesn't, and this process is in the socket's group** (`DOCKER_HOST`'s
  unix socket, else `/var/run/docker.sock`): the reaper unit runs through
  `sg <group> -c '<reaper command>'`, once a second probe through `sg`
  succeeds. `sg` is setuid `newgrp`. It grants a group the group database
  lists the user in, with no password and no re-login, so the reaper keeps
  its systemd parent and still outlives the test. The environment passes
  through `sg` unchanged.
- **It still can't:** the child-process reaper below, with a warning that a
  killed test may leave its cluster until the next launcher's sweep. If the
  test is in the group, the warning says to log out and back in (or restart
  `user@<uid>.service`).
- **The probe itself can't run** (e.g. a systemd-run without `--pipe`; the
  status line is missing): the unit is used as before, with a note.

Rootless podman's socket belongs to the user, so podman setups always take
the first branch.

A delete refused with "permission denied" is now logged as "the reaper cannot
reach the container runtime: permission denied on <socket> (group …; this
process has groups …)", not as "still present after kind delete". After 3
such refusals in a row the reaper gives up: credentials don't change under a
running process, and while the reaper lives, the next launcher's sweep
(which runs with the test's groups) skips the cluster. Before v0.3.1 it
retried for the full 30 minutes. `reaper_access_test` covers all of this
with fake `systemd-run`, `docker`, `sg` and `kind` binaries.

**Child process (fallback).** If `systemd-run --user` fails (no user
manager, no D-Bus), or a unit can't reach the runtime even through `sg`
(above), the launcher starts `launcher.py --reap <kind> <name>`
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

Output goes to `~/.local/state/rules_kind/<cluster>.log` (same file as the
launcher's own log) in both modes. Before v0.3.0 it went to
`$TEST_TMPDIR/<target>.reaper.log`, which Bazel removes with the test, so a
failed reaper left no trace.

`RULES_KIND_KEEP_CLUSTER=1` disables both the launcher's deletion and the
reaper, writes no ownership record, and logs the command to delete the
cluster by hand.

### Ownership records and sweep

`$XDG_STATE_HOME/rules_kind` (default `~/.local/state/rules_kind`, from the
passwd home because Bazel sets `HOME=$TEST_TMPDIR`) holds, per cluster:

- `<cluster>.json` — the ownership record: boot id, launcher pid + start
  time, runtime, target, and the reaper (unit name, or pid + start time).
  Written before `kind create`; removed by whoever confirms the deletion.
- `<cluster>.log` — launcher and reaper log. Removed after a clean teardown;
  logs without a record are pruned after 7 days.

Every launcher, before taking a slot, sweeps the records: a record whose
launcher is not alive (another boot, or the pid has another start time) and
whose reaper is not alive (unit inactive, or pid gone) belongs to a leaked
cluster, which it deletes (one confirmed attempt; the record stays if that
fails). A non-blocking `flock` on the record keeps two launchers from
sweeping the same cluster. The sweep only sees this user's records and only
clusters of the runtime the launcher detected. `launcher.py --sweep <kind>`
runs it by hand.

The sweep deletes leaked clusters whether or not their nodes still run: the
record proves rules_kind created them, and with launcher and reaper gone
nobody else will. Clusters from before v0.3.0 have no record and are left
alone.

### Admission

A launcher takes one of `RULES_KIND_MAX_CLUSTERS` (default 2; `0` = no limit)
slots before `kind create cluster`: `slot-<i>` files in
`RULES_KIND_SLOT_DIR` (default `$XDG_RUNTIME_DIR/rules_kind/slots`, per user),
each locked with a non-blocking `flock` and polled every 2 s. The fd stays open
until the launcher exits, and the kernel releases the lock on any exit,
SIGKILL included; fds are not inherited by children (Python's default), so
`conmon` and friends can't keep a slot. The holder writes its cluster, pid
and target into the slot file, and a waiting launcher logs those holders once
a minute. Slot files are mode 0666 so that a directory shared between users
(mode 1777) works. With `RULES_KIND_MIN_FREE_MB` the launcher also waits,
after taking the slot, until `/proc/meminfo`'s `MemAvailable` reaches it.

Why 2: one cluster per user serializes even small clusters on large
machines; three full-platform clusters (#15) exhausted a 16-core, 125 GB
host. The waiting time counts against the test's timeout; rules_itest has no
health-check timeout unless `health_check_timeout` is set.

The limit is per user by default because the issue's suggested directory,
`$XDG_RUNTIME_DIR`, is per user, and a world-writable default would let any
user hold every slot. `RULES_KIND_SLOT_DIR` opts a host into a shared limit.

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

- **`kind_cleanup` tool**: `bazel run //tools:kind_cleanup` wrapping
  `launcher.py --sweep` (v0.3.0) with the right kind binary.
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

## Release archive contents (v0.3.2)

`tests/` is `export-ignore` (`.gitattributes`): its packages load dev-only modules (rules_shell), which made `@rules_kind//...` unloadable for consumers. `REPO.bazel` `ignore_directories` would also hide them from this repo's own `bazel test`, so it isn't used. A `git_override` clone still contains them. CI's `consumer` job (`.github/consumer/check.sh`) checks the commit's `git archive`: the directories are absent and `@rules_kind//...` loads for a consumer.

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
  for its whole 30-minute retry window, and without a systemd user instance it
  doesn't survive the end of the test (see Reaper). The next launcher's sweep
  deletes such clusters (see Ownership records and sweep); until a launcher
  runs, they stay.
- **The cluster limit is per user by default** (`RULES_KIND_SLOT_DIR` shares
  it) and counts launchers, not cluster size.
- **Target name collision.** Two `kind_cluster` targets with the same local
  name in different packages write to the same env file path.
- **Windows not supported** (no pre-built binary source; PRs welcome).
