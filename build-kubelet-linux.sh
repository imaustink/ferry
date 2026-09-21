#!/usr/bin/env bash
# Builds a linux/arm64 kubelet for the mode 2 guest, from the same upstream
# source as the Mac's, with the volume manager's poll intervals shortened and
# nothing else changed.
#
# Mode 2's node is a Linux VM, so it needs a Linux kubelet, and
# experiments/17-node-vm/stage.sh has always downloaded upstream's. That is
# the right default -- it is the binary everyone else runs, and building it is
# minutes -- but it also means mode 2 pays the 300ms volume wait that
# ferry_shorten_volume_polls takes off mode 1. Measured: mode 1 went from
# 710ms to 431ms on a single pod while mode 2, unpatched, stayed at 497ms.
#
# This is deliberately not build-kubelet.sh with a different GOOS. That script
# exists to make a kubelet run on macOS at all: it adds _darwin.go files,
# retags portable fallbacks and rewrites kubelet_pods.go where it lies. None
# of that belongs in a Linux build, and running it first would leave the tree
# carrying darwin shims that Linux compiles anyway. So this takes its own
# clean checkout and applies exactly one change.
#
#   ./build-kubelet-linux.sh              # into experiments/17-node-vm/stage
#   OUT=/tmp/kubelet ./build-kubelet-linux.sh
#
# stage.sh keeps whatever is already at stage/kubelet, so this is what decides
# which kubelet the node image bakes in. Delete stage/kubelet to go back to
# upstream's.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
FERRY_ROOT="$here"
export FERRY_ROOT
# shellcheck source=lib/versions.sh
. "$here/lib/versions.sh"
# shellcheck source=lib/overlay.sh
. "$here/lib/overlay.sh"

K8S_VERSION="${K8S_VERSION:-$(ferry_active_version)}"
K8S_VERSION="${K8S_VERSION:-$FERRY_DEFAULT_K8S_VERSION}"
ferry_version_valid "$K8S_VERSION" \
  || { echo "K8S_VERSION=$K8S_VERSION is not a version like v1.34.0" >&2; exit 1; }

# The guest runs the control plane's version, the same answer stage.sh gets,
# so this cannot drift from the binary it replaces.
GUEST_VERSION="$(ferry_control_plane_version "$K8S_VERSION")"

# A checkout of its own. build-kubelet.sh reuses
# ${TMPDIR}/ferry-kubernetes-<version> and overlays it for darwin; sharing it
# would mean each build undoing the other's work on every run.
src="${K8S_LINUX_SRC:-${TMPDIR:-/tmp}/ferry-kubernetes-linux-$GUEST_VERSION}"
out="${OUT:-$here/experiments/17-node-vm/stage/kubelet}"
mkdir -p "$(dirname "$out")"

if [ ! -d "$src" ]; then
  echo "==> cloning kubernetes $GUEST_VERSION"
  git clone --depth 1 --branch "$GUEST_VERSION" --single-branch \
    https://github.com/kubernetes/kubernetes.git "$src"
else
  echo "==> reusing source at $src"
  # Back to upstream before rewriting, so a changed FERRY_VOLUME_*_MS is not
  # applied on top of the last run's numbers.
  git -C "$src" checkout -- . 2>/dev/null || true
fi

echo "==> shortening the volume manager's poll intervals"
ferry_shorten_volume_polls "$src" || exit 1
echo "    ~ pkg/kubelet/volumemanager/volume_manager.go"

# The version the binary reports, which is what the Node object's VERSION
# column shows and what skew checks read. Without these the kubelet calls
# itself v0.0.0-master and a node that is exactly the right version registers
# looking like it is not. Same set build-kubelet.sh stamps, against
# GUEST_VERSION because that is what this actually built.
ldflags="-s -w$(
  for pkg in k8s.io/client-go/pkg/version k8s.io/component-base/version; do
    echo -n " -X $pkg.gitVersion=$GUEST_VERSION"
    echo -n " -X $pkg.gitMajor=$(echo "$GUEST_VERSION" | cut -d. -f1 | tr -d v)"
    echo -n " -X $pkg.gitMinor=$(echo "$GUEST_VERSION" | cut -d. -f2)"
    echo -n " -X $pkg.gitTreeState=clean"
    echo -n " -X $pkg.buildDate=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  done
)"

echo "==> building linux/arm64 kubelet ($GUEST_VERSION)"
cd "$src"
# CGO off: this is a cross-build from macOS, and the guest kubelet has no need
# of it. The Mac's does -- it reads CPU through the Mach host port -- but in
# the guest /proc/stat is there and cadvisor reads it.
rm -f "$out"
# -s -w in ldflags above: upstream ships a stripped binary and this goes into
# an ext4 that is copied per machine, so an unstripped 120MB against
# upstream's 54MB is 66MB of node image for debug symbols nothing here reads.
GOFLAGS=-mod=vendor GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
  go build -ldflags "$ldflags" -o "$out" ./cmd/kubelet

# stage.sh writes this beside the binary and the node image build reads it, so
# a kubelet built here has to leave the same note a downloaded one would.
echo "$GUEST_VERSION" > "$(dirname "$out")/kubelet.version"
# So stage.sh can say which kubelet it staged rather than leaving the two
# indistinguishable. Only when this built into the staging directory: OUT
# elsewhere is someone taking the binary for their own purposes.
if [ "$out" = "$here/experiments/17-node-vm/stage/kubelet" ]; then
  touch "$(dirname "$out")/kubelet.ferry-built"
fi

echo "==> $out"
ls -lh "$out"
echo "    rebuild the node image to pick it up: ./ferry node-image"
