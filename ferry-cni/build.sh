#!/usr/bin/env bash
# Builds ferry-cni and the two halves of its plugin set.
#
# The interesting part is that there are two halves at all. Upstream's IPAM
# plugins are arithmetic and files, so they build native Mach-O and run on the
# Mac; the meta plugins want netlink and netfilter, so they cross-build static
# ELF and run inside a pod's own kernel. Neither is patched.
#
# Each artifact's type is asserted rather than assumed. A first pass at this
# experiment reported everything as Linux-only for the wrong reason -- the
# module's dependencies were unresolved and every build failed -- so a build
# that quietly produces nothing is exactly the failure mode to guard against.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"

P=github.com/containernetworking/plugins/plugins
# Run on the Mac. host-local is what ferry's own address allocator reimplemented,
# and it keeps its leases on disk, which ferry's never did.
HOST_PLUGINS="ipam/host-local ipam/static"
# Run inside the pod VM. portmap is hostPort, which ferry does not have; the
# others are per-pod shaping and sysctls, which ferry has no way to express.
GUEST_PLUGINS="meta/portmap meta/bandwidth meta/tuning"

hostdir="$here/plugins/host"
guestdir="$here/plugins/guest"
rm -rf "$here/plugins"
mkdir -p "$hostdir" "$guestdir" "$root/bin"

# Asserts a built artifact is the architecture it was asked to be, and dies
# saying which one it got if not.
assert_type() {
  local path="$1" want="$2" got
  got="$(file -b "$path")"
  case "$got" in
    *"$want"*) return 0 ;;
    *) echo "$(basename "$path"): expected $want, got $got" >&2; exit 1 ;;
  esac
}

echo "==> ferry-cni"
( cd "$here" && GOOS=darwin GOARCH=arm64 go build -o "$root/bin/ferry-cni" . )
assert_type "$root/bin/ferry-cni" "Mach-O 64-bit executable arm64"
echo "    $root/bin/ferry-cni"

echo "==> the main plugin, for the Mac"
( cd "$here" && GOOS=darwin GOARCH=arm64 go build -o "$hostdir/ferry-vm" ./ferry-vm )
assert_type "$hostdir/ferry-vm" "Mach-O 64-bit executable arm64"
echo "    ferry-vm"

echo "==> upstream plugins that need no Linux, for the Mac"
for plugin in $HOST_PLUGINS; do
  ( cd "$here/upstream" && GOFLAGS=-mod=mod GOOS=darwin GOARCH=arm64 \
      go build -o "$hostdir/$(basename "$plugin")" "$P/$plugin" )
  assert_type "$hostdir/$(basename "$plugin")" "Mach-O 64-bit executable arm64"
  echo "    $(basename "$plugin")"
done

# Static, because a pod's image cannot be relied on to have a libc -- the same
# problem guest/build-nft.sh solves by shipping musl, and Go does not have it.
echo "==> upstream plugins that need Linux, for the pod"
for plugin in $GUEST_PLUGINS; do
  ( cd "$here/upstream" && GOFLAGS=-mod=mod CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
      go build -ldflags "-s -w" -o "$guestdir/$(basename "$plugin")" "$P/$plugin" )
  assert_type "$guestdir/$(basename "$plugin")" "ELF 64-bit LSB executable, ARM aarch64"
  assert_type "$guestdir/$(basename "$plugin")" "statically linked"
  echo "    $(basename "$plugin")"
done

# ferry's own guest plugin. Same shape as the upstream ones -- static ELF, run
# inside the pod -- and built from this repository rather than fetched.
echo "==> ferry's plugin, for the pod"
( cd "$here/ferry-sctp" && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
    go build -ldflags "-s -w" -o "$guestdir/ferry-sctp" . )
assert_type "$guestdir/ferry-sctp" "ELF 64-bit LSB executable, ARM aarch64"
assert_type "$guestdir/ferry-sctp" "statically linked"
echo "    ferry-sctp"

echo "==> $here/plugins ($(du -sh "$here/plugins" | cut -f1))"
