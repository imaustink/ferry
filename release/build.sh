#!/usr/bin/env bash
# Package a built checkout into the tarball 'install.sh' downloads.
#
# ferry is a shell script that drives a directory, not a single binary, so a
# release is not one file the way k3s' is. It is the subset of this checkout a
# cluster actually reads at runtime: the CLI, the version store, the guest
# kernel, the CNI plugins, nft, and the manifests. Everything a *build* needs --
# patches/, the Swift and Go sources, build-kubelet.sh, experiments/ -- is left
# out, because the whole point is that the machine unpacking this has no
# toolchain.
#
# What decides the contents is ferry itself: every path it opens at runtime is
# copied below, and tests/release-test.sh fails if ferry grows a reference to
# something this does not ship.
#
#   ./release/build.sh [--version vX.Y.Z] [--out dist]
#
# The binaries are copied, never rebuilt or stripped. Two reasons, both already
# paid for elsewhere in this tree: `strip` invalidates the ad-hoc signature the
# Go linker puts on every arm64 binary, and macOS answers an invalid signature
# with a bare "Killed: 9"; and ferry-cri carries
# com.apple.security.virtualization, without which Virtualization.framework
# refuses to make a VM at all. An ad-hoc signature is a hash of the binary
# itself, so it survives the move to another Mac -- which is what makes
# shipping these at all possible, and is the same property 'ferry join' has
# relied on since it told people to copy bin/ over by hand.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
export FERRY_ROOT="$root"
# shellcheck source=../lib/versions.sh
. "$root/lib/versions.sh"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

version=""
out="$root/dist"
node_image=1
while [ $# -gt 0 ]; do
  case "$1" in
    --version) version="${2:-}"; shift 2 ;;
    --version=*) version="${1#*=}"; shift ;;
    --out) out="${2:-}"; shift 2 ;;
    --out=*) out="${1#*=}"; shift ;;
    # Mode 2 is opt-in on the Mac that installs this, but the image it needs
    # weighs a couple of hundred megabytes and takes a Docker build to make. A
    # release without it is a legitimate thing to want; a release that quietly
    # lacks it is not, so this is a flag rather than a silent skip, and VERSION
    # records the answer for 'ferry machines' to read.
    --without-node-image) node_image=""; shift ;;
    *) die "usage: release/build.sh [--version vX.Y.Z] [--out <dir>] [--without-node-image]" ;;
  esac
done

# What this release is called. A tag if HEAD is one, because that is the thing
# users will ask for by name; otherwise a version that is visibly not a release,
# so a hand-built tarball cannot be mistaken for a published one.
if [ -z "$version" ]; then
  version="$(git -C "$root" describe --tags --exact-match 2>/dev/null)" \
    || version="v0.0.0-dev.$(date -u +%Y%m%d).$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
fi

# The tar runs from inside the staging directory, so a relative --out -- which
# is the form this script's own usage line shows -- would resolve under the
# temp stage rather than the caller's cwd, and be deleted by the EXIT trap if it
# resolved anywhere at all. Absolute from here on.
case "$out" in
  /*) : ;;
  *)  out="$(pwd)/$out" ;;
esac

k8s="$(ferry_active_version)"
[ -n "$k8s" ] || die "this checkout has not been built -- run: ./ferry build"
ferry_version_complete "$k8s" || die "the version store has no complete $k8s -- run: ./ferry build"

bold "packaging ferry $version"
echo "  kubernetes  $k8s (control plane $(ferry_manifest_field "$k8s" control-plane 2>/dev/null || echo '?'), etcd $(ferry_manifest_field "$k8s" etcd 2>/dev/null || echo '?'))"
echo "  from        $root"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
dir="$stage/ferry-$version"
mkdir -p "$dir"

# --- the CLI and what it sources -----------------------------------------
cp "$root/ferry" "$dir/ferry"
chmod +x "$dir/ferry"
mkdir -p "$dir/lib"
# The whole directory rather than the files ferry happens to source today. A
# named list is a second place to remember, and the way it fails is a release
# that builds, publishes and then dies on its first command because the file
# it sources was never in the tarball.
cp "$root"/lib/*.sh "$dir/lib/"

# The control plane's own scripts. fetch-binaries.sh comes along even though
# this tarball already carries the binaries: 'ferry upgrade apply' fetches a
# *different* version, and an installed ferry has to be able to upgrade without
# growing a toolchain to do it.
mkdir -p "$dir/control-plane"
cp "$root/control-plane/"*.sh "$dir/control-plane/"

cp -R "$root/manifests" "$dir/manifests"
cp -R "$root/addons" "$dir/addons"
# Mode 2's CRD. It is applied by 'ferry machines enable', so it is a runtime
# asset in exactly the way manifests/coredns.yaml is -- the Go sources beside it
# are not shipped.
mkdir -p "$dir/ferry-machined"
cp "$root/ferry-machined/crd.yaml" "$dir/ferry-machined/"
ok "cli, control plane scripts, manifests, addons and the Machine CRD"

# --- the guest ------------------------------------------------------------
# The NAT-capable kernel is the one that matters: without it Services fall back
# to a host proxy that needs root, which is exactly the experience this release
# exists to avoid. The kata fallback kernel is deliberately not shipped -- it is
# 15MB spent on making the product worse.
[ -f "$root/kernel/vmlinux-arm64" ] \
  || die "no guest kernel at kernel/vmlinux-arm64 -- run: ./ferry kernel (slow, needs docker)"
# A kernel from before a patch boots and works, and quietly costs every pod what
# the patch saved -- 75 MiB each, for the read-ahead one -- so it is not shipped.
[ "$(FERRY_ROOT="$root" ferry_kernel_inputs)" = "$(cat "$root/kernel/vmlinux-arm64.inputs" 2>/dev/null)" ] \
  || die "kernel/vmlinux-arm64 was built from other patches or configuration -- run: ./ferry kernel"
mkdir -p "$dir/kernel"
cp "$root/kernel/vmlinux-arm64" "$dir/kernel/"
ok "guest kernel with NAT support"

[ -x "$root/guest/nft/nft" ] || die "guest/nft is missing -- run: ./guest/build-nft.sh"
mkdir -p "$dir/guest"
cp -R "$root/guest/nft" "$dir/guest/nft"
ok "nft, with its loader"

mkdir -p "$dir/ferry-cni/plugins"
for side in host guest; do
  [ -d "$root/ferry-cni/plugins/$side" ] \
    || die "ferry-cni/plugins/$side is missing -- run: ./ferry-cni/build.sh"
  cp -R "$root/ferry-cni/plugins/$side" "$dir/ferry-cni/plugins/$side"
done
ok "cni plugins, both architectures"

# --- the binaries ---------------------------------------------------------
# The version store is copied for the active version and re-linked on this side.
# The symlinks are recreated rather than carried: tar would either dereference
# them -- shipping eight copies of the same 100MB kubelet -- or preserve links
# whose targets depend on what else made it into the archive.
mkdir -p "$dir/bin/versions/$k8s"
for name in $FERRY_VERSIONED_BINARIES; do
  src="$(ferry_version_dir "$k8s")/$name"
  [ -f "$src" ] || continue
  cp "$src" "$dir/bin/versions/$k8s/$name"
  chmod +x "$dir/bin/versions/$k8s/$name"
  ln -sf "versions/$k8s/$name" "$dir/bin/$name"
done
cp "$(ferry_version_dir "$k8s")/MANIFEST" "$dir/bin/versions/$k8s/MANIFEST" 2>/dev/null || true
echo "$k8s" > "$dir/bin/.active-version"
ok "kubernetes $k8s"

# ferry's own binaries, which are this checkout's code rather than Kubernetes'
# and so are not in the version store.
for name in ferry-cri ferry-cni ferry-gpud ferry-netpol ferry-proxy ferry-storage ferry-streamer \
            ferry-machined ferry-node ferry-karpenter ferry-registry; do
  [ -x "$root/bin/$name" ] || die "bin/$name is missing -- run: ./ferry build"
  cp "$root/bin/$name" "$dir/bin/$name"
  chmod +x "$dir/bin/$name"
done
ok "runtime, streamer, cni, proxy, netpol, storage, gpud, machined, node, karpenter, registry"

# The entitlement is the one thing in here that copying the file again cannot
# repair, so it is checked rather than assumed.
if ! codesign -d --entitlements - "$dir/bin/ferry-cri" 2>&1 | grep -q virtualization; then
  die "bin/ferry-cri has no virtualization entitlement -- rebuild it: (cd ferry-cri && ./build.sh)"
fi
# ferry-node makes the VM a machine runs in, so it needs the same entitlement
# and fails the same way without it: Virtualization.framework simply refuses.
if ! codesign -d --entitlements - "$dir/bin/ferry-node" 2>&1 | grep -q virtualization; then
  die "bin/ferry-node has no virtualization entitlement -- rebuild it: ./ferry build"
fi
ok "ferry-cri and ferry-node carry com.apple.security.virtualization"

# --- the mode 2 node image ------------------------------------------------
# The OCI layout rather than the unpacked ext4: the layout is the compressed
# layers, and 'ferry machines enable' unpacks it to a disk on first use with
# ferry-node's own unpacker. That keeps Docker off the installing Mac -- Docker
# is only needed to *create* the layout -- and keeps ~400MB of mostly-zero
# sparse file out of the tarball.
if [ -n "$node_image" ]; then
  [ -d "$root/node-image/oci" ] \
    || die "no node image at node-image/oci -- run: ./ferry node-image (slow, needs docker), or pass --without-node-image"
  mkdir -p "$dir/node-image"
  cp -R "$root/node-image/oci" "$dir/node-image/oci"
  ok "mode 2 node image ($(du -sh "$root/node-image/oci" | awk '{print $1}'))"
else
  ok "no node image (--without-node-image); mode 2 will say so rather than fail oddly"
fi

# --- what the far side reads to know what it has --------------------------
# The Swift version is recorded because a cluster spans Macs and two toolchains
# produce two builds that are only probably the same. With a release, every Mac
# gets the same binaries -- this says which toolchain made them.
cat > "$dir/VERSION" <<META
ferry=$version
kubernetes=$k8s
control-plane=$(ferry_manifest_field "$k8s" control-plane 2>/dev/null || echo unknown)
etcd=$(ferry_manifest_field "$k8s" etcd 2>/dev/null || echo unknown)
node-image=$([ -n "$node_image" ] && echo yes || echo no)
commit=$(git -C "$root" rev-parse HEAD 2>/dev/null || echo unknown)
swift=$(swift --version 2>&1 | grep -oE 'Apple Swift version [0-9.]+' | head -1 | awk '{print $4}')
built=$(date -u +%Y-%m-%dT%H:%M:%SZ)
META
ok "VERSION"

# --- the tarball ----------------------------------------------------------
mkdir -p "$out"
tarball="$out/ferry-$version-darwin-arm64.tar.gz"
rm -f "$tarball"
# --no-mac-metadata keeps bsdtar from writing ._ AppleDouble members, which are
# noise on every other system and carry the quarantine flag on this one.
( cd "$stage" && tar --no-mac-metadata -czf "$tarball" "ferry-$version" ) \
  || die "could not write $tarball"

( cd "$out" && shasum -a 256 "$(basename "$tarball")" > "$(basename "$tarball").sha256" )

echo
bold "built $(basename "$tarball")"
echo "  $tarball"
echo "  $(du -h "$tarball" | awk '{print $1}')  $(awk '{print $1}' "$tarball.sha256")"
echo
echo "  publish it:  ./release/publish.sh --version $version"
