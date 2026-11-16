#!/usr/bin/env python3
"""Assemble a docker-archive tarball (`docker save` format) from OCI blobs.

Run by the kube-bench image repository rule (private/kube_bench_image.bzl):

    docker_archive.py <out.tar> <repo tag> <image manifest> <blobs dir>

The image manifest is an OCI / Docker v2 image manifest whose config and
layers are files named by their hex digest in <blobs dir>. Layers stay
compressed: `docker load` and containerd's importer (`kind load
image-archive`) both detect the compression. The tar is deterministic
(sorted, mtime 0, uid/gid 0), so the same pins give the same file.
"""

import hashlib
import io
import json
import os
import sys
import tarfile


def _hex(digest):
    algo, _, value = digest.partition(":")
    if algo != "sha256" or len(value) != 64:
        raise SystemExit("docker_archive: unsupported digest {!r}".format(digest))
    return value


def _add(tar, name, data=None, path=None):
    info = tarfile.TarInfo(name)
    info.mtime = 0
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    info.mode = 0o644
    if path is not None:
        info.size = os.path.getsize(path)
        with open(path, "rb") as f:
            tar.addfile(info, f)
    else:
        info.size = len(data)
        tar.addfile(info, io.BytesIO(data))


def _verify(path, want_hex):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    if h.hexdigest() != want_hex:
        raise SystemExit("docker_archive: {} has sha256 {}, want {}".format(path, h.hexdigest(), want_hex))


def main(argv):
    if len(argv) != 5:
        raise SystemExit(__doc__)
    out, repo_tag, manifest_path, blobs = argv[1:]
    with open(manifest_path, encoding="utf-8") as f:
        manifest = json.load(f)
    config_hex = _hex(manifest["config"]["digest"])
    layers = [_hex(layer["digest"]) for layer in manifest["layers"]]
    for h in [config_hex] + layers:
        _verify(os.path.join(blobs, h), h)

    config_name = config_hex + ".json"
    layer_names = [h + ".tar.gz" for h in layers]
    docker_manifest = [{
        "Config": config_name,
        "RepoTags": [repo_tag],
        "Layers": layer_names,
    }]
    with tarfile.open(out, "w", format=tarfile.GNU_FORMAT) as tar:
        _add(tar, config_name, path=os.path.join(blobs, config_hex))
        seen = set()
        for h, name in zip(layers, layer_names):
            if name in seen:  # a layer listed twice is stored once
                continue
            seen.add(name)
            _add(tar, name, path=os.path.join(blobs, h))
        _add(tar, "manifest.json", data=(json.dumps(docker_manifest, sort_keys=True) + "\n").encode())


if __name__ == "__main__":
    main(sys.argv)
