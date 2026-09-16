#!/usr/bin/env bash
# Builds the guest initramfs and the host probe.
#
# Same shape as experiment 03: Virtualization.framework refuses to create a VM
# without the entitlement, so the binary is ad-hoc signed after linking. This
# builds with swiftc directly rather than SwiftPM, which also means it does not
# care whether the toolchain's package manager half is in working order.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"
mkdir -p build/root/proc

echo "==> guest init (linux/arm64, static)"
( cd init && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
    go build -trimpath -ldflags='-s -w' -o "$here/build/root/init" . )

echo "==> initramfs"
( cd build/root && ls | cpio -o -H newc --quiet > ../initramfs.cpio )
ls -lh build/initramfs.cpio

echo "==> probe (swiftc + ad-hoc sign)"
swiftc -O -o build/balloon main.swift -framework Virtualization
codesign --force --sign - --entitlements entitlements.plist build/balloon
codesign -d --entitlements - build/balloon 2>&1 | grep -i virtualization || true

echo "==> ready: build/balloon"
