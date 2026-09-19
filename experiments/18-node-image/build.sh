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
rm -rf stage && mkdir stage
cp "$STAGE/kubelet" "$STAGE/runc" "$STAGE/containerd.tar.gz" "$STAGE/cni-plugins.tgz" stage/

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
