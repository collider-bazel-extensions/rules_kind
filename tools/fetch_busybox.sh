#!/usr/bin/env bash
# Maintainer-time script: pull busybox:stable + emit a kind-loadable
# tarball into tests/testdata/busybox.tar.
#
# Why vendored: rootless-podman in CI can't resolve registry-1.docker.io
# from inside the kind node's pod network (slirp4netns/pasta DNS
# routing). Preloading the image via `kind load image-archive` at
# cluster boot sidesteps the runtime pull entirely. See DESIGN.md
# "Vendored test images" for the full reasoning.
#
# Re-run when busybox upstream bumps a major version or the tag's
# digest changes in a way that breaks behavior. `:stable` is a moving
# tag; today's commit is good for `kubectl run -- echo hello` which
# is all the test needs.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# Use podman or docker — both produce kind-loadable archives via
# `--format=docker-archive`.
if command -v podman >/dev/null 2>&1; then
    runtime=podman
elif command -v docker >/dev/null 2>&1; then
    runtime=docker
else
    echo "fetch_busybox: needs podman or docker on PATH" >&2
    exit 1
fi

# Pin to linux/amd64 — the CI matrix is amd64-only and we want the
# committed tarball to be deterministic regardless of which host
# arch the maintainer runs on.
"$runtime" pull --platform=linux/amd64 docker.io/library/busybox:stable

dest="tests/testdata/busybox.tar"
if [[ "$runtime" == "podman" ]]; then
    podman save --format=docker-archive -o "$dest" busybox:stable
else
    docker save busybox:stable > "$dest"
fi

sha=$(sha256sum "$dest" | awk '{print $1}')
size=$(stat -c%s "$dest")
echo
echo "fetch_busybox: wrote $dest"
echo "  size:   $size bytes"
echo "  sha256: $sha"
