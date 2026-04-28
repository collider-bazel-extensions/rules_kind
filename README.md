# rules_kind

Bazel rules for running full Kubernetes clusters in integration tests using
[kind](https://kind.sigs.k8s.io) (Kubernetes IN Docker). Provides real clusters
with a working kubelet and container runtime for end-to-end tests that require
actual pod execution. Designed for use with
[rules_itest](https://github.com/dzbarsky/rules_itest).

```
bazel test //myapp/...   # kind cluster shared across all services in each service_test
```

## What it does

`rules_kind` creates a full Kubernetes cluster via kind:

- Creates a `kind` cluster with a real kubelet and container runtime.
- Pre-loads container image tarballs via `kind load image-archive`.
- Applies Kubernetes manifests (`kubectl apply -f`).
- Writes `$TEST_TMPDIR/<name>.env` when the cluster is fully ready.
- Blocks until SIGTERM, then runs `kind delete cluster`.

## What you can test

- Full operator lifecycle: deploy an image, apply CRDs, create custom resources,
  observe reconciliation via pod logs or HTTP endpoints.
- Services that run inside pods: HTTP APIs, background workers, sidecars.
- Init container sequencing and volume data flow.
- Readiness and liveness probe behavior.
- Node affinity, taints, tolerations, and real scheduling decisions.

## What you cannot test

- Multi-node behaviour requiring real hardware (NUMA, SR-IOV, GPUs).
- Production network topology (kind uses a bridge network inside Docker).
- Performance benchmarks (Docker adds overhead; nodes share the host kernel).

---

## Installation

### Requirements

- Docker **or** podman must be installed and running on the test host.
  The launcher auto-detects which runtime is available.
- `kind` must be installed (auto-detected from `$PATH` or `~/.local/bin`).
- `kubectl` must be installed (auto-detected from `$PATH` or `~/.local/bin`).

**Rootless podman** (Fedora, RHEL, etc.) works automatically. The launcher
re-executes itself under `systemd-run --scope --user --property=Delegate=yes`
when podman requires cgroup delegation.

Install kind:

```sh
# macOS
brew install kind

# Linux
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.22.0/kind-linux-amd64
chmod +x ./kind && sudo mv ./kind /usr/local/bin/kind
```

### Bzlmod (`MODULE.bazel`)

```python
bazel_dep(name = "rules_kind", version = "0.1.2")

kind = use_extension("@rules_kind//:extensions.bzl", "kind")

# Use host-installed kind + kubectl (auto-detects from PATH):
kind.system(versions = ["1.29", "1.32"])

use_repo(kind,
    "kind_1_29_linux_amd64",
    "kind_1_29_darwin_arm64",
    "kind_1_29_darwin_amd64",
    "kind_1_32_linux_amd64",
    "kind_1_32_darwin_arm64",
    "kind_1_32_darwin_amd64",
)
```

Supported `k8s_version` values:

| Version | kindest/node | kind binary | kubectl | Notes |
|---|---|---|---|---|
| `1.29` | `v1.29.2` | `v0.22.0` | `1.29.2` | Default. runc 1.1.12 — see caveat below. |
| `1.32` | `v1.32.2` | `v0.27.0` | `1.32.2` | runc 1.2.5. Required for workloads that bind-mount configmaps under rootless container engines on kernel 6.x (e.g. Cilium agent, kube-proxy). |

### WORKSPACE (legacy)

```python
load("@rules_kind//:repositories.bzl", "kind_system_dependencies")

kind_system_dependencies(versions = ["1.29", "1.32"])
```

### Sandbox bypass

kind requires Docker. Bazel's linux-sandbox blocks `/var/run/docker.sock`.
All `kind_cluster` targets must bypass the sandbox:

```python
kind_cluster(
    name = "k8s",
    tags = ["no-sandbox", "requires-docker"],
    ...
)
```

Or globally via `.bazelrc`:

```
test:kind --strategy=TestRunner=local
```

---

## Quick start

```python
# BUILD.bazel
load("@rules_kind//:defs.bzl", "kind_cluster", "kind_health_check")
load("@rules_itest//:defs.bzl", "itest_service", "service_test")

kind_cluster(
    name        = "k8s",
    k8s_version = "1.29",
    tags        = ["no-sandbox", "requires-docker"],
)

kind_health_check(
    name    = "k8s_health",
    cluster = ":k8s",
)

itest_service(
    name         = "k8s_svc",
    exe          = ":k8s",
    health_check = ":k8s_health",
)

service_test(
    name     = "e2e_test",
    test     = ":e2e_test_bin",
    services = [":k8s_svc"],
)
```

```bash
# e2e_test.sh
set -euo pipefail

source "$TEST_TMPDIR/k8s.env"

# KUBECONFIG, KIND_CLUSTER_NAME, KUBE_API_SERVER, and KUBECTL are now set.
"$KUBECTL" get nodes --kubeconfig "$KUBECONFIG"
echo "PASS"
```

---

## Examples

### Operator end-to-end test

Deploy an operator image, apply CRDs, create a custom resource, and verify
reconciliation.

```python
# BUILD.bazel
load("@rules_kind//:defs.bzl", "kind_cluster", "kind_health_check")
load("@rules_itest//:defs.bzl", "itest_service", "service_test")

kind_cluster(
    name        = "k8s",
    k8s_version = "1.29",
    images      = ["//cmd/operator:image_tar"],   # rules_oci oci_tarball target
    manifests   = glob(["config/crd/*.yaml"]),
    tags        = ["no-sandbox", "requires-docker"],
)

kind_health_check(name = "k8s_health", cluster = ":k8s")

itest_service(
    name         = "k8s_svc",
    exe          = ":k8s",
    health_check = ":k8s_health",
)

service_test(
    name     = "operator_e2e_test",
    test     = ":operator_e2e_test_bin",
    services = [":k8s_svc"],
)
```

```bash
# operator_e2e_test.sh
set -euo pipefail

source "$TEST_TMPDIR/k8s.env"

# Apply a custom resource and verify the operator reconciles it.
"$KUBECTL" apply --kubeconfig "$KUBECONFIG" -f - <<EOF
apiVersion: mygroup.example.com/v1
kind: MyResource
metadata:
  name: test-resource
  namespace: default
spec:
  replicas: 1
EOF

# Wait for the operator to set status.ready=true.
for i in $(seq 1 30); do
    ready=$("$KUBECTL" get myresource test-resource \
        --kubeconfig "$KUBECONFIG" \
        -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
    [[ "$ready" == "true" ]] && break
    sleep 2
done

[[ "$ready" == "true" ]] || { echo "FAIL: resource never became ready" >&2; exit 1; }
echo "PASS"
```

---

### Pod-to-pod communication

This example shows how to test that one pod can reach another over the cluster's
internal DNS. A busybox HTTP server is deployed via the `kind_cluster` manifest;
a client pod then fetches from it by Service name.

```
tests/
├── BUILD.bazel
├── pod_to_pod_test.sh
└── manifests/
    └── hello_server.yaml   ← server Pod + ClusterIP Service
```

```yaml
# tests/manifests/hello_server.yaml
---
apiVersion: v1
kind: Pod
metadata:
  name: hello-server
  namespace: default
  labels:
    app: hello-server
spec:
  automountServiceAccountToken: false
  containers:
  - name: server
    image: busybox:stable
    command:
    - sh
    - -c
    - |
      mkdir -p /srv
      echo 'Hello from rules_kind' > /srv/index.html
      httpd -f -p 8080 -h /srv/
    ports:
    - containerPort: 8080
    readinessProbe:
      tcpSocket:
        port: 8080
      initialDelaySeconds: 1
      periodSeconds: 2
---
apiVersion: v1
kind: Service
metadata:
  name: hello-server
  namespace: default
spec:
  selector:
    app: hello-server
  ports:
  - port: 8080
    targetPort: 8080
```

```python
# tests/BUILD.bazel
kind_cluster(
    name      = "pod_to_pod_cluster",
    k8s_version = "1.29",
    manifests = ["manifests/hello_server.yaml"],   # server deployed at startup
    tags      = ["no-sandbox", "requires-docker"],
)

kind_health_check(name = "pod_to_pod_cluster_health", cluster = ":pod_to_pod_cluster")

sh_test(
    name = "pod_to_pod_test",
    srcs = ["pod_to_pod_test.sh"],
    data = [":pod_to_pod_cluster"],
    size = "large",
    tags = ["no-sandbox", "requires-docker"],
)
```

```bash
# tests/pod_to_pod_test.sh
set -euo pipefail

source "$TEST_TMPDIR/pod_to_pod_cluster.env"

# Wait for the server pod to reach Running.
deadline=$(( $(date +%s) + 60 ))
phase=""
while [[ "$phase" != "Running" ]]; do
    [[ $(date +%s) -le $deadline ]] || { echo "FAIL: server pod timeout" >&2; exit 1; }
    phase=$("$KUBECTL" get pod hello-server --namespace default \
        --kubeconfig "$KUBECONFIG" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
    sleep 2
done

# Run a client pod that fetches from the server via its Service DNS name.
# The cluster DNS resolves 'hello-server' to the ClusterIP of the Service.
"$KUBECTL" run hello-client \
    --image=busybox:stable \
    --restart=Never \
    --namespace default \
    --kubeconfig "$KUBECONFIG" \
    --overrides='{"spec":{"automountServiceAccountToken":false}}' \
    -- sh -c 'wget -qO- http://hello-server:8080/'

# Wait for the client pod to complete.
deadline=$(( $(date +%s) + 60 ))
phase=""
while [[ "$phase" != "Succeeded" ]]; do
    [[ $(date +%s) -le $deadline ]] || { echo "FAIL: client pod timeout" >&2; exit 1; }
    [[ "$phase" != "Failed" ]] || { echo "FAIL: client pod failed" >&2; exit 1; }
    phase=$("$KUBECTL" get pod hello-client --namespace default \
        --kubeconfig "$KUBECONFIG" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
    sleep 2
done

# Verify the response body.
response=$("$KUBECTL" logs hello-client --namespace default --kubeconfig "$KUBECONFIG")
[[ "$response" == *"Hello from rules_kind"* ]] || {
    echo "FAIL: unexpected response: $response" >&2; exit 1; }

echo "PASS: client received '$response' from server"
```

> **Note on ServiceAccount timing.** The Kubernetes controller-manager creates
> the `default` ServiceAccount in each namespace asynchronously after the API
> server starts. The `rules_kind` launcher automatically waits for it before
> applying manifests. Pod manifests should set
> `automountServiceAccountToken: false` to avoid depending on the SA being
> present at pod scheduling time.

---

### Multi-service test: operator + API server + database

```python
# BUILD.bazel
load("@rules_kind//:defs.bzl", "kind_cluster", "kind_health_check")
load("@rules_pg//defs.bzl", "pg_server", "pg_health_check", "postgres_schema")
load("@rules_itest//:defs.bzl", "itest_service", "service_test")

postgres_schema(
    name = "schema",
    srcs = glob(["migrations/*.sql"]),
)

pg_server(name = "db",   schema = ":schema")
pg_health_check(name = "db_health", server = ":db")

kind_cluster(
    name      = "k8s",
    k8s_version = "1.29",
    images    = ["//cmd/operator:image_tar"],
    manifests = glob(["config/**/*.yaml"]),
    tags      = ["no-sandbox", "requires-docker"],
)

kind_health_check(name = "k8s_health", cluster = ":k8s")

itest_service(name = "db_svc",  exe = ":db",  health_check = ":db_health")
itest_service(name = "k8s_svc", exe = ":k8s", health_check = ":k8s_health")

itest_service(
    name = "api_svc",
    exe  = "//cmd/api",
    deps = [":db_svc", ":k8s_svc"],
    http_health_check_address = "http://127.0.0.1:${PORT}/healthz",
    autoassign_port = True,
)

service_test(
    name     = "e2e_test",
    test     = ":e2e_test_bin",
    services = [":db_svc", ":k8s_svc", ":api_svc"],
)
```

```bash
# e2e_test.sh
set -euo pipefail

# Source kubernetes connection details.
source "$TEST_TMPDIR/k8s.env"

# Source database connection details.
source "$TEST_TMPDIR/db.env"

# Get API server port from rules_itest.
API_PORT=$(echo "$ASSIGNED_PORTS" | python3 -c "
import json, sys
print(json.load(sys.stdin)['//myapp:api_svc'])
")

# Verify cluster is reachable.
"$KUBECTL" get nodes --kubeconfig "$KUBECONFIG" >/dev/null

# Verify API talks to the database.
curl -sf "http://127.0.0.1:${API_PORT}/healthz"
echo "PASS"
```

---

## Public API

```python
load("@rules_kind//:defs.bzl",
    "kind_cluster",
    "kind_health_check",
)

# Long-running kind cluster for rules_itest multi-service tests.
kind_cluster(
    name        = "k8s",
    k8s_version = "1.29",          # optional, default "1.29"
    config      = ":kind_config",  # optional: kind config YAML file (Label)
    images      = [                # optional: Docker image tarballs to pre-load
        "//myapp:server_image_tar",
        "//myapp:worker_image_tar",
    ],
    manifests   = glob(["config/**/*.yaml"]),  # optional: YAML files to apply
    tags        = ["no-sandbox", "requires-docker"],
)

# Health-check binary for rules_itest (exits 0 when k8s is fully ready).
kind_health_check(
    name    = "k8s_health",
    cluster = ":k8s",
)
```

### `kind_cluster` attributes

| Attribute     | Type          | Default  | Description |
|---------------|---------------|----------|-------------|
| `k8s_version` | string        | `"1.29"` | Kubernetes minor version. Selects the `kindest/node` image. |
| `config`      | label         | `None`   | kind config YAML file. Controls node count, port mappings, feature gates. |
| `images`      | label_list    | `[]`     | Docker image tarball targets to pre-load via `kind load image-archive`. |
| `manifests`   | label_list    | `[]`     | YAML files to apply via `kubectl apply -f` after cluster is ready. |

### Environment variables written to the env file

| Variable            | Example                        | Description                           |
|---------------------|--------------------------------|---------------------------------------|
| `KUBECONFIG`        | `$TEST_TMPDIR/kubeconfig`      | Kubeconfig for the kind cluster       |
| `KIND_CLUSTER_NAME` | `kind-abc123def456`            | Unique cluster name                   |
| `KUBE_API_SERVER`   | `https://127.0.0.1:6443`       | API server address                    |
| `KUBECTL`           | `/path/to/kubectl`             | Absolute path to kubectl              |

---

## Integration with rules_itest

```python
kind_cluster(name = "k8s", k8s_version = "1.29", images = [":app_image_tar"])
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

### Lifecycle

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

## Binary acquisition

Two modes are available:

| Mode | MODULE.bazel tag | WORKSPACE function | Description |
|---|---|---|---|
| System | `kind.system()` | `kind_system_dependencies()` | Symlinks host-installed kind + kubectl |
| Download | `kind.version()` | `kind_dependencies()` | Downloads binaries from GitHub / dl.k8s.io |

**Auto-detection** (`kind.system()`) — when `bin_dir` is omitted, the
repository rule:

1. Runs `command -v kind` (PATH lookup).
2. Probes common locations: `/usr/local/bin`, `/usr/bin`, `~/.local/bin`.

If kind cannot be found, the build fails with a clear error and a suggested
install command.

Platforms supported: `linux_amd64`, `darwin_arm64`, `darwin_amd64`.

---

## Development

### Running the self-tests

```sh
# Health check test (no container runtime needed):
bazel test //tests/...

# All tests including cluster tests (requires kind + Docker or podman).
# For rootless podman, wrap in a delegated systemd scope:
systemd-run --scope --user --property=Delegate=yes -- \
    bazel test //tests:kind_health_check_test //tests:kind_server_test \
        //tests:cluster_test //tests:manifest_test \
        --strategy=TestRunner=local
```

---

## Known limitations

- **Docker required.** Tests must run outside the Bazel linux-sandbox
  (`tags = ["no-sandbox"]` or `--strategy=TestRunner=local`).
- **Startup time ~30–90 s.** kind is unsuitable for per-test isolation; use
  one shared cluster per `service_test`.
- **No `kind_test` macro.** All usage goes through `rules_itest`.
- **Image loading is sequential.** Multiple `images` are loaded one at a time
  via `kind load image-archive`. Large images slow cluster startup.
- **Cluster name collision.** Two `kind_cluster` targets with the same local
  name in different packages would write to the same `$TEST_TMPDIR/<name>.env`.
  Use unique target names within a test run.
- **Windows not supported** (no pre-built binary source; PRs welcome).
- **Downloaded binary SHA-256 checksums** are placeholder values. Pin real
  values before using `kind.version()`.
