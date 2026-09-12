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
swift build -c release
cp "$(swift build -c release --show-bin-path)/ferry-cri" ../bin/ferry-cri
codesign --force --sign - --entitlements entitlements.plist ../bin/ferry-cri
echo "==> $(cd .. && pwd)/bin/ferry-cri"
