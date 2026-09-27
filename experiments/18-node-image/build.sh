#!/usr/bin/env bash
# Builds the node image and the tool that turns it into a bootable disk.
#
# The image is built with `ferry image build --export`, the same
# buildkit-in-a-pod path docs/RUNTIMES.md#building-an-image-without-docker
# documents, exported as an OCI layout tarball and unpacked into an ext4 a
# VM boots from. It is never run as a container -- Docker's only past job
# here was producing that same tarball, and ferry's own builder produces
# byte-for-byte the same `type=oci` shape (buildkit under both).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

# The exact ferry this checkout builds with, not whatever is on PATH --
# cmd_node_image always execs this script from a checkout's own $here, so
# the repo root two levels up is always the matching one.
FERRY="${FERRY:-$here/../../ferry}"
[ -x "$FERRY" ] || { echo "$FERRY not found or not executable -- run this from a checkout" >&2; exit 1; }
command -v buildctl >/dev/null || { echo "buildctl is required (brew install buildkit)" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl is required (brew install kubectl, or 'ferry doctor')" >&2; exit 1; }
: "${KUBECONFIG:=$HOME/.ferry/admin.conf}"
export KUBECONFIG
kubectl get nodes >/dev/null 2>&1 || { echo "no cluster reachable -- run 'ferry up' first" >&2; exit 1; }

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
# No Dockerfile of its own to build -- just buildkit resolving and pulling
# a FROM, the same first step every other build already does. --no-load
# because this tar is for the node's own containerd to import at boot
# (init.sh, `ctr images import`), not a pod on this dev cluster; --export
# writes the OCI-layout tar ctr autodetects and imports same as a
# docker-save tar.
sandbox_ctx="$(mktemp -d "${TMPDIR:-/tmp}/ferry-sandbox-pull.XXXXXX")"
printf 'FROM %s\n' "$SANDBOX_IMAGE" > "$sandbox_ctx/Dockerfile"
"$FERRY" image build -f "$sandbox_ctx/Dockerfile" -t sandbox-pin:local \
  --export stage/sandbox-image.tar --no-load --quiet "$sandbox_ctx"
rm -rf "$sandbox_ctx"

echo "==> ferry image build ($TAG, linux/arm64)"
"$FERRY" image build -t "$TAG" --export "$here/build/node-oci.tar" --no-load --quiet .

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
