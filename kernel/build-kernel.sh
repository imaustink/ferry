#!/usr/bin/env bash
# Builds a guest kernel with NAT support.
#
# The default guest kernel comes from kata-containers, which ships netfilter
# without the NAT extensions:
#
#     iptables -t nat -A ...
#       Warning: Extension DNAT revision 0 not supported, missing kernel module?
#     /proc/net/ip_tables_names -> no nat table
#
# and the kernel is monolithic, so nothing can be loaded at runtime. Without NAT
# a pod cannot program Service rules in its own kernel, which is what forces
# ClusterIP routing onto the host and with it the root requirement and the extra
# hop through the Mac.
#
# Apple's own kernel configuration does enable it -- CONFIG_NF_NAT,
# CONFIG_NF_CONNTRACK, CONFIG_NF_NAT_MASQUERADE, CONFIG_NF_TABLES -- so this
# builds that configuration rather than inventing one. The build runs in a Linux
# container because it needs a cross toolchain; Apple drives it with their
# `container` CLI, and Docker serves equally well.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
CONTAINERIZATION_REF="${CONTAINERIZATION_REF:-0.45.0}"
KERNEL_SOURCE="${KERNEL_SOURCE:-https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.5.tar.xz}"
out="$here/vmlinux-arm64"
work="$here/.build"

if [ -f "$out" ] && [ "${FORCE:-}" != "1" ]; then
  echo "==> kernel present: $out (FORCE=1 to rebuild)"
  exit 0
fi

command -v docker >/dev/null || { echo "docker is required to build the kernel" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "docker is not running" >&2; exit 1; }

mkdir -p "$work"

# Take the configuration and build recipe from Apple's repository rather than
# vendoring them, so the kernel tracks what the framework expects.
if [ ! -d "$work/containerization" ]; then
  echo "==> fetching containerization $CONTAINERIZATION_REF for its kernel config"
  git clone --depth 1 --branch "$CONTAINERIZATION_REF" \
    https://github.com/apple/containerization.git "$work/containerization" 2>&1 | tail -1
fi
src="$work/containerization/kernel"
[ -f "$src/config-arm64" ] || { echo "no kernel config in $src" >&2; exit 1; }

echo "==> confirming the configuration actually enables NAT"
for symbol in CONFIG_NF_NAT CONFIG_NF_CONNTRACK CONFIG_NF_TABLES CONFIG_NF_NAT_MASQUERADE; do
  if grep -q "^${symbol}=y" "$src/config-arm64"; then
    printf '    %-28s y\n' "$symbol"
  else
    echo "    $symbol MISSING -- this kernel would not fix Services" >&2
    exit 1
  fi
done

if [ ! -f "$work/source.tar.xz" ]; then
  echo "==> downloading $(basename "$KERNEL_SOURCE")"
  curl -fSL --progress-bar -o "$work/source.tar.xz" "$KERNEL_SOURCE"
fi

echo "==> building the toolchain image"
docker build -q -t ferry-kernel-build:1 "$src/image" >/dev/null

echo "==> compiling (this takes a while)"
stage="$work/stage"
rm -rf "$stage"; mkdir -p "$stage"
cp "$src/config-arm64" "$src/build.sh" "$stage/"
cp "$work/source.tar.xz" "$stage/"
docker run --rm -v "$stage:/kernel" -w /kernel \
  -e TARGET_ARCH=arm64 -e LOCALVERSION=-ferry \
  ferry-kernel-build:1 bash /kernel/build.sh

[ -f "$stage/vmlinux-arm64" ] || { echo "build produced no kernel" >&2; exit 1; }
install -m 0644 "$stage/vmlinux-arm64" "$out"
rm -rf "$stage"

echo "==> $out"
file "$out"
