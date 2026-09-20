#!/usr/bin/env bash
# Builds the node image and the tool that turns it into a bootable disk.
#
# Docker builds the image because that is the tooling everyone has; the image is
# exported as an OCI layout and unpacked into an ext4 a VM boots from. It is
# never run as a container.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

SWIFT="${SWIFT:-swift}"
TAG="${TAG:-ferry-node:dev}"
LAYOUT="${LAYOUT:-$here/build/oci}"
DISK="${DISK:-$here/build/node.ext4}"
SIZE_GIB="${SIZE_GIB:-8}"

mkdir -p build

# The node's software comes from experiment 17's staging directory: the kubelet
# has to match the control plane, and downloading it again here would be a
# second place for the version to drift.
STAGE="${STAGE:-$here/../17-node-vm/stage}"
[ -f "$STAGE/kubelet" ] || { echo "run ../17-node-vm/stage.sh first"; exit 1; }

# files/containerd-config.toml is `version = 3` with the io.containerd.cri.v1
# plugin names, which only containerd 2.x reads. A 1.x staged through
# CONTAINERD_VERSION would take the config, refuse it at startup and never open
# its socket -- a node that boots, waits a minute and has no kubelet. Caught
# here rather than there.
CONTAINERD_STAGED="$(cat "$STAGE/containerd.version" 2>/dev/null || true)"
case "$CONTAINERD_STAGED" in
  2.*) ;;
  "") echo "$STAGE has no containerd.version; re-run ../17-node-vm/stage.sh"; exit 1 ;;
  *)  echo "staged containerd $CONTAINERD_STAGED: files/containerd-config.toml needs 2.x"; exit 1 ;;
esac

rm -rf stage && mkdir stage
cp "$STAGE/kubelet" "$STAGE/runc" "$STAGE/containerd.tar.gz" "$STAGE/cni-plugins.tgz" stage/

# The sandbox image, baked in rather than pulled on first use. stage.sh says the
# node downloads nothing at boot; that was true of every binary and false of
# this one image, which containerd fetched the first time a pod was scheduled.
#
# Which image is not decided here: it is read out of the containerd config that
# ships in the node image, so the pin and the baked copy cannot drift. The trick
# is kind's -- see pkg/build/nodeimage/helpers.go.
#
# Anchored to a line that sets it, and only the first one: an unanchored match
# over the whole file would also pick up a commented-out alternative and hand
# docker two image names on one line.
SANDBOX_IMAGE="$(grep -E "^[[:space:]]*sandbox = '[^']+'" files/containerd-config.toml \
  | head -1 | sed "s/.*sandbox = '//;s/'.*//")"
[ -n "$SANDBOX_IMAGE" ] || { echo "no sandbox image pinned in files/containerd-config.toml"; exit 1; }
echo "==> sandbox image $SANDBOX_IMAGE"
docker pull --platform linux/arm64 -q "$SANDBOX_IMAGE" >/dev/null
docker save -o stage/sandbox-image.tar "$SANDBOX_IMAGE"

# The default buildx driver cannot export an OCI layout, which is the format
# the image has to arrive in to be unpacked into a filesystem. A
# docker-container builder can.
BUILDER="${BUILDER:-ferry-node-builder}"
if ! docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
  echo "==> creating buildx builder $BUILDER"
  docker buildx create --name "$BUILDER" --driver docker-container >/dev/null
fi

echo "==> docker build ($TAG, linux/arm64)"
docker buildx build --builder "$BUILDER" --platform linux/arm64 -t "$TAG" \
  -o "type=oci,dest=$here/build/node-oci.tar" . >/dev/null

rm -rf "$LAYOUT" && mkdir -p "$LAYOUT"
tar xf "$here/build/node-oci.tar" -C "$LAYOUT"

echo "==> ferry-node"
"$SWIFT" build -c release
cp "$("$SWIFT" build -c release --show-bin-path)/ferry-node" build/ferry-node
# Virtualization.framework refuses to create a VM without the entitlement.
codesign --force --sign - --entitlements entitlements.plist build/ferry-node
codesign -d --entitlements - build/ferry-node 2>&1 | grep -i virtualization || true

echo "==> disk"
./build/ferry-node build --layout "$LAYOUT" --out "$DISK" --size-gib "$SIZE_GIB"
ls -lh "$DISK"
du -m "$DISK" | awk '{print "    " $1 " MiB actually on disk"}'
