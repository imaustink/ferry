#!/usr/bin/env bash
# Virtualization.framework refuses to create a VM without the entitlement, so
# the binary is ad-hoc signed at its final path -- signing inside .build and
# copying afterwards produces a binary that is killed on launch, the same
# ferry-cri/build.sh note applies here.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"
# SWIFT lets a working toolchain be named when the default one is not. macOS
# ships SwiftPM and the compiler as separate pieces of the developer tools and
# a half-applied update leaves them disagreeing, which fails in the manifest
# before any of this code is even read.
SWIFT="${SWIFT:-swift}"
# swift build -c release, without the Command Line Tools' noise and without
# Swift 6.4's needless full rebuilds (lib/swift-build.sh says why).
# shellcheck source=../lib/swift-build.sh
. "$here/../lib/swift-build.sh"
ferry_swift_build
mkdir -p ../bin
rm -f ../bin/ferry-macvm
cp "$("$SWIFT" build -c release --show-bin-path)/ferry-macvm" ../bin/ferry-macvm
codesign --force --sign - --entitlements entitlements.plist ../bin/ferry-macvm
echo "==> $(cd .. && pwd)/bin/ferry-macvm"
