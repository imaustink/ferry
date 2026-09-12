#!/usr/bin/env bash
# Fetches the guest kernel. This is the same kata-containers build that Apple's
# Containerization framework pulls by default, so the VM ceiling measured here
# reflects the kernel the real runtime will boot.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
KATA_VERSION="${KATA_VERSION:-3.17.0}"
out="$here/assets/vmlinux-arm64"

if [ -f "$out" ]; then echo "==> kernel present: $out"; exit 0; fi

mkdir -p "$here/assets"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "==> fetching kata-containers $KATA_VERSION (~290 MB, for a 14 MB kernel)"
curl -fsSL -o "$tmp/kata.tar.xz" \
  "https://github.com/kata-containers/kata-containers/releases/download/$KATA_VERSION/kata-static-$KATA_VERSION-arm64.tar.xz"

# vmlinux.container is a symlink to a versioned file, so resolve it before
# extracting -- pulling the link alone leaves a dangling path.
tar -xJf "$tmp/kata.tar.xz" -C "$tmp" --strip-components=1 \
  ./opt/kata/share/kata-containers/vmlinux.container
target="$(readlink "$tmp/opt/kata/share/kata-containers/vmlinux.container")"
tar -xJf "$tmp/kata.tar.xz" -C "$tmp" --strip-components=1 \
  "./opt/kata/share/kata-containers/$target"

install -m 0644 "$tmp/opt/kata/share/kata-containers/$target" "$out"
echo "==> $out"
file "$out"
