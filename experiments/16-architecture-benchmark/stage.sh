#!/usr/bin/env bash
# Downloads the container runtime the node-VM architecture needs, once, on the
# host. The guest gets them through a shared directory rather than fetching them
# itself: the versions stay fixed across runs, the measured path has no network
# in it, and a benchmark that repeats twenty times does not repeat the download
# twenty times.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

STAGE="${STAGE:-$here/stage}"
CONTAINERD_VERSION="${CONTAINERD_VERSION:-2.3.5}"
RUNC_VERSION="${RUNC_VERSION:-1.5.1}"

mkdir -p "$STAGE"

if [ ! -f "$STAGE/containerd.tar.gz" ]; then
  echo "==> containerd $CONTAINERD_VERSION"
  curl -sSL -o "$STAGE/containerd.tar.gz" \
    "https://github.com/containerd/containerd/releases/download/v$CONTAINERD_VERSION/containerd-$CONTAINERD_VERSION-linux-arm64.tar.gz"
fi

if [ ! -f "$STAGE/runc" ]; then
  echo "==> runc $RUNC_VERSION"
  curl -sSL -o "$STAGE/runc" \
    "https://github.com/opencontainers/runc/releases/download/v$RUNC_VERSION/runc.arm64"
  chmod +x "$STAGE/runc"
fi

# containerd pulls over TLS and the base image carries no trust store, so the
# Mac's bundle goes in too.
if [ ! -f "$STAGE/ca-certificates.crt" ]; then
  echo "==> CA bundle"
  cp /etc/ssl/cert.pem "$STAGE/ca-certificates.crt"
fi

ls -lh "$STAGE"
echo "==> staged in $STAGE"
