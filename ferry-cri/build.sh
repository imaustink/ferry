#!/usr/bin/env bash
# Virtualization.framework refuses to create a VM without the entitlement, so
# the binary is ad-hoc signed. Sign the final path: signing inside .build and
# copying afterwards produces binaries that are killed on launch.
#
# Do NOT add com.apple.vm.networking. It is restricted, it is not needed for
# vmnet, and an ad-hoc binary claiming it is SIGKILLed at launch.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"
# SWIFT lets a working toolchain be named when the default one is not. macOS
# ships SwiftPM and the compiler as separate pieces of the developer tools and
# a half-applied update leaves them disagreeing, which fails in the manifest
# before any of this code is even read.
SWIFT="${SWIFT:-swift}"
"$SWIFT" build -c release
cp "$("$SWIFT" build -c release --show-bin-path)/ferry-cri" ../bin/ferry-cri
codesign --force --sign - --entitlements entitlements.plist ../bin/ferry-cri
echo "==> $(cd .. && pwd)/bin/ferry-cri"

# The interactive guest agent (kubectl exec -i/-it). A tiny macOS binary ferry-cri
# uploads into a booted guest and launches on vsock 7001 -- no change to the
# golden image. Ad-hoc signed, like the baked agent.
swiftc -O -target arm64-apple-macos26.0 -o ../bin/ferry-macagent-i guest/ferry-macagent-i.swift
codesign --force --sign - ../bin/ferry-macagent-i
echo "==> $(cd .. && pwd)/bin/ferry-macagent-i"

# The search-list DNS forwarder (multi-label short names like svc.namespace).
# macOS appends search domains only to single-label names; ferry-cri uploads this
# into the guest and points the pod's resolver at it. Ad-hoc signed.
swiftc -O -target arm64-apple-macos26.0 -o ../bin/ferry-macdns guest/ferry-macdns.swift
codesign --force --sign - ../bin/ferry-macdns
echo "==> $(cd .. && pwd)/bin/ferry-macdns"
