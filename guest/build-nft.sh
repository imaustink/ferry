#!/usr/bin/env bash
# Packages the nft binary ferry loads Service rules with inside pods.
#
# kube-proxy expresses rules as nftables text, so applying them needs nft. A
# pod's image cannot be relied on to have it -- or to share a libc with it -- so
# nft is shipped together with its own musl loader and libraries and invoked
# through that loader explicitly. That works whatever the pod's base image is:
# verified loading a ruleset inside a glibc Debian container.
#
# Building nft statically would be tidier, but it drags in static readline and
# gmp that Alpine does not package, and this is about 3 MB either way.
#
# The loader is also baked into the binary, so nft runs as an ordinary command
# as well. That matters for CNI: portmap's nftables backend shells out to
# whatever `nft` it finds on PATH, and it cannot be told to go through a loader.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$here/nft"
ALPINE="${ALPINE:-alpine:3.20}"

if [ -x "$out/nft" ] && [ "${FORCE:-}" != "1" ]; then
  echo "==> nft bundle present: $out (FORCE=1 to rebuild)"
  exit 0
fi

command -v docker >/dev/null || { echo "docker is required to package nft" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "docker is not running" >&2; exit 1; }

rm -rf "$out"; mkdir -p "$out"
echo "==> packaging nft and its loader from $ALPINE"
docker run --rm --platform linux/arm64 -v "$out:/out" "$ALPINE" sh -c '
  apk add --no-cache nftables patchelf >/dev/null 2>&1
  mkdir -p /out/lib
  cp /usr/sbin/nft /out/nft
  for lib in $(ldd /usr/sbin/nft 2>/dev/null | grep -oE "/[^ ]+\.so[^ ]*" | sort -u); do
    [ -f "$lib" ] && cp -L "$lib" /out/lib/
  done
  cp -L /lib/ld-musl-aarch64.so.1 /out/lib/ 2>/dev/null || true
  # Point the binary at the loader and libraries where the pod will see them,
  # so `nft` works as a command and not only through an explicit loader call.
  patchelf --set-interpreter /.ferry/lib/ld-musl-aarch64.so.1 \
           --set-rpath /.ferry/lib /out/nft
'
[ -x "$out/nft" ] || { echo "packaging produced no nft" >&2; exit 1; }
echo "==> $out ($(du -sh "$out" | cut -f1))"
