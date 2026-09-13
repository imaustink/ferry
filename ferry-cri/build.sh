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
