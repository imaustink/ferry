#!/usr/bin/env bash
# Builds the guest initramfs and the host probe.
#
# The probe needs the com.apple.security.virtualization entitlement or
# Virtualization.framework refuses to create a VM, so the binary is ad-hoc
# signed after linking. Ad-hoc is enough for a locally built, locally run tool.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"
mkdir -p build/root

echo "==> guest init (linux/arm64, static)"
( cd init && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
    go build -trimpath -ldflags='-s -w' -o "$here/build/root/init" . )

echo "==> initramfs"
( cd build/root && ls | cpio -o -H newc --quiet > ../initramfs.cpio )
ls -lh build/initramfs.cpio

echo "==> probe (swiftc + ad-hoc sign)"
swiftc -O -o build/vmceiling main.swift -framework Virtualization
codesign --force --sign - --entitlements entitlements.plist build/vmceiling
codesign -d --entitlements - build/vmceiling 2>&1 | grep -i virtualization || true

echo "==> ready: build/vmceiling"
