# rules_kind

Bazel rules for running full Kubernetes clusters in tests using
[kind](https://kind.sigs.k8s.io) (Kubernetes IN Docker). Provides real
clusters with a working kubelet and container runtime for end-to-end tests
that require actual pod execution. Designed for use with
[rules_itest](https://github.com/dzbarsky/rules_itest).

## Commit requirements

- All tests must pass before any commit with code changes (`bazel test //tests/...`).
- All documentation (`README.md`, `DESIGN.md`, `CLAUDE.md`) must be updated to
  reflect any code changes before committing. This includes new rules, changed
  attributes, new public API surface, and behaviour changes.

## Repo layout

```
rules_kind/
├── MODULE.bazel              # Bzlmod module definition
├── WORKSPACE                 # Legacy workspace (compatibility shim)
├── defs.bzl                  # Public API re-exports
├── extensions.bzl            # Module extension: kind + kubectl binary repos
├── repositories.bzl          # Legacy WORKSPACE equivalents of extensions.bzl
├── BUILD.bazel               # Platform config_settings + kind_binary targets
├── DESIGN.md                 # Architecture and design decisions
├── private/
│   ├── binary.bzl            # kind_binary rule + KindBinaryInfo provider
│   ├── cluster.bzl           # kind_cluster rule + kind_health_check rule
│   └── launcher.py           # Launcher: kind create → load images → apply manifests → write env
├── toolchain/
│   └── toolchain.bzl         # Toolchain type + register helpers
└── tests/
    ├── BUILD.bazel
    ├── cluster_test.sh              # Basic cluster connectivity + pod scheduling
    ├── manifest_test.sh             # Manifest applied before env file written
    ├── kind_health_check_test.sh    # Health check behavior
    └── kind_server_test.sh          # Cluster lifecycle, env file, SIGTERM shutdown
```

## Key concepts

### `kind_cluster` service model

`kind_cluster` is a long-running service — it does not wrap a test binary
directly. Every use of `kind_cluster` goes through `rules_itest`:

```
rules_itest service manager
  ├── starts :k8s_svc        (kind_cluster: kind create → load images → apply manifests → write env file)
  │     polls :k8s_health    (exits 0 when $TEST_TMPDIR/<name>.env exists)
  └── runs test binary       (sources env file, uses KUBECONFIG + KIND_CLUSTER_NAME)
  └── sends SIGTERM to all services
        :k8s_svc → kind delete cluster
```

There is no `kind_test` macro — kind clusters take 30–90 s to start and are
unsuitable for per-test isolation. One cluster is shared across all services
and test binaries in a `service_test`.

### Docker requirement

`kind_cluster` requires Docker to be available at test runtime. Bazel's
linux-sandbox blocks `/var/run/docker.sock`, so tests must run outside the
sandbox:

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

### Launcher modes

The launcher (`private/launcher.py`) supports two modes set by `RULES_KIND_MODE`:

| Mode | Env var | Behaviour |
|------|---------|-----------|
| `cluster` (default) | `RULES_KIND_MANIFEST` | kind create → load images → apply manifests → write env file → signal.pause() |

There is only one mode. `kind_cluster` is always a long-running service; it is
never exec'd directly into a test binary.

### Cluster lifecycle

```
_allocate_cluster_name()   → kind-<uuid>
  ↓
kind create cluster --name <name> --config <config>
  ↓
_wait_apiserver_ready()    → kubectl cluster-info (max 120 s)
  ↓
kind load docker-image     → load each image into cluster nodes (if images provided)
  ↓
kubectl apply -f           → apply manifests in order (if manifests provided)
  ↓
write $TEST_TMPDIR/<name>.env atomically   ← readiness signal
  ↓
install SIGTERM + SIGINT handlers
  ↓
signal.pause()
  ↓
SIGTERM → kind delete cluster --name <name>
```

### Binary acquisition

`extensions.bzl` (Bzlmod) and `repositories.bzl` (WORKSPACE) both support two
modes:

| Tag / function                  | Behavior                                           |
|---------------------------------|----------------------------------------------------|
| `kind.version()`                | Downloads kind + kubectl binaries from GitHub      |
| `kind.system()`                 | Symlinks host-installed kind + kubectl             |
| `kind_system_dependencies()`    | WORKSPACE equivalent of `kind.system()`            |

**Auto-detection** — when `bin_dir` is omitted, the repository rule:

1. Runs `command -v kind` (PATH lookup).
2. Probes common locations: `/usr/local/bin`, `/usr/bin`,
   `$HOME/.local/bin`.

If kind cannot be found, the build fails with a clear error and a suggested
install command.

Download source:
- kind: `https://github.com/kubernetes-sigs/kind/releases/download/v{version}/kind-linux-amd64`
- kubectl: `https://dl.k8s.io/release/v{k8s_version}/bin/linux/amd64/kubectl`

Platforms supported: `linux_amd64`, `darwin_arm64`, `darwin_amd64`.

### `kind_cluster` readiness protocol

`kind_cluster` writes `$TEST_TMPDIR/<name>.env` atomically (via temp file +
`os.replace`) once the cluster is fully ready — after `kind create`, image
loads, and manifest application:

```
KUBECONFIG=/tmp/.../kubeconfig
KIND_CLUSTER_NAME=kind-abc123
KUBE_API_SERVER=https://127.0.0.1:<port>
KUBECTL=/path/to/kubectl
```

`kind_health_check` exits 0 iff this file exists.

### Sandbox

`kind_cluster` tests must run with `tags = ["no-sandbox"]` or
`--strategy=TestRunner=local` because:

1. Docker socket (`/var/run/docker.sock`) is inaccessible from inside
   Bazel's linux-sandbox.
2. `kind create cluster` manipulates Docker networks and volumes, which
   require host namespace access.

All other rules in this package (analysis, build steps) run normally in the
sandbox. Only the test execution step needs sandbox bypass.

### Combined launcher manifest

`kind_cluster` generates a JSON manifest at build time:

```json
{
  "workspace":      "<workspace_name>",
  "kind_bin":       "<runfile path>",
  "kubectl_bin":    "<runfile path>",
  "kind_config":    "<runfile path>",
  "k8s_version":   "1.29",
  "images":         ["myapp/server:test", "myapp/worker:test"],
  "manifest_files": ["config/crd/foo.yaml", "config/rbac/role.yaml"]
}
```

`kind_config`, `images`, and `manifest_files` are omitted when not provided.

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
    config      = ":kind_config",  # optional: kind config file (Label)
    images      = [                # optional: Docker images to pre-load
        "//myapp:server_image",
        "//myapp:worker_image",
    ],
    manifests   = ":crds",         # optional: kubernetes_manifest target
    tags        = ["no-sandbox", "requires-docker"],
)

# Health-check binary for rules_itest (exits 0 when k8s is fully ready).
kind_health_check(
    name    = "k8s_health",
    cluster = ":k8s",
)
```

### Environment variables written to the env file

| Variable            | Example                        | Description                           |
|---------------------|--------------------------------|---------------------------------------|
| `KUBECONFIG`        | `$TEST_TMPDIR/kubeconfig`      | Kubeconfig for the kind cluster       |
| `KIND_CLUSTER_NAME` | `kind-abc123def456`            | Unique cluster name                   |
| `KUBE_API_SERVER`   | `https://127.0.0.1:6443`       | API server address                    |
| `KUBECTL`           | `/path/to/kubectl`             | Absolute path to kubectl              |

### MODULE.bazel (Bzlmod)

```python
bazel_dep(name = "rules_kind", version = "0.1.0")

kind = use_extension("@rules_kind//:extensions.bzl", "kind")

# Use host-installed kind + kubectl (auto-detects from PATH):
kind.system(versions = ["1.29"])

use_repo(kind,
    "kind_1_29_linux_amd64",
    "kind_1_29_darwin_arm64",
    "kind_1_29_darwin_amd64",
)
```

### WORKSPACE (legacy)

```python
load("@rules_kind//:repositories.bzl", "kind_system_dependencies")

kind_system_dependencies(versions = ["1.29"])
```

## Development

### Running the self-tests

```sh
bazel test //tests/... --strategy=TestRunner=local
```

Tests require Docker. The `--strategy=TestRunner=local` flag bypasses the
linux-sandbox so the Docker socket is accessible.

All tests must pass before any commit with code changes.

### Test results (last full run: pending)

Tests not yet implemented.

### Launcher script

`private/launcher.py` is the heart of `kind_cluster`. The launcher:

1. Reads the JSON manifest (`RULES_KIND_MANIFEST`).
2. Resolves all runfile paths.
3. Generates a unique cluster name (`kind-<12hex>`).
4. Runs `kind create cluster --name <name>` with optional `--config`.
5. Extracts the kubeconfig via `kind get kubeconfig --name <name>`.
6. Waits for the API server (`kubectl cluster-info`, max 120 s).
7. Loads Docker images into cluster nodes via `kind load docker-image`.
8. Applies manifest files via `kubectl apply -f` in order.
9. Writes `$TEST_TMPDIR/<name>.env` atomically.
10. Installs SIGTERM/SIGINT handlers.
11. Blocks via `signal.pause()`.
12. On signal: `kind delete cluster --name <name>` then exits 0.

### Test script requirements

All test shell scripts must:
- Begin with `set -euo pipefail`.
- Source `$TEST_TMPDIR/<cluster-name>.env` to get connection details.
- Use `"$KUBECTL"` (not bare `kubectl`) — kubectl is injected via the env file.
- Pass `--kubeconfig "$KUBECONFIG"` on all kubectl calls.

### Style

- All `.bzl` files use 4-space indentation.
- Provider fields are documented with inline comments.
- Public rules/macros have docstrings.
- `private/` contains implementation details; only `defs.bzl` is the stable API.

## Known limitations

- **Docker required.** Tests must run outside the Bazel linux-sandbox
  (`tags = ["no-sandbox"]` or `--strategy=TestRunner=local`).
- **Startup time ~30–90 s.** kind is unsuitable for per-test isolation; use
  one shared cluster per `service_test`.
- **No `kind_test` macro.** All usage goes through `rules_itest`.
- **Image loading is sequential.** Multiple `images` are loaded one at a time
  via `kind load docker-image`. Large images slow cluster startup.
- **Cluster name collision.** Two `kind_cluster` targets with the same local
  name in different packages would write to the same `$TEST_TMPDIR/<name>.env`.
  Use unique target names within a test run.
- **Windows not supported** (no pre-built binary source; PRs welcome).
- **Downloaded binary SHA-256 checksums** are placeholder values. Pin real
  values before using `kind.version()`.
