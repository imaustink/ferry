#!/usr/bin/env bash
# Rebuilds just the tool, for when the image has not changed.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"
SWIFT="${SWIFT:-swift}"
# OUT lets 'ferry build' put this straight into bin/ rather than leaving the
# only copy under experiments/. The copy and the signature have to land on the
# same path: signing inside .build and copying afterwards produces a binary
# macOS kills at launch, which is the same rule ferry-cri's build follows.
OUT="${OUT:-$here/build/ferry-node}"
mkdir -p "$(dirname "$OUT")"
# swift build -c release, without the Command Line Tools' noise and without
# Swift 6.4's needless full rebuilds (lib/swift-build.sh says why).
# shellcheck source=../../lib/swift-build.sh
. "$here/../../lib/swift-build.sh"
ferry_swift_build
rm -f "$OUT"
cp "$("$SWIFT" build -c release --show-bin-path)/ferry-node" "$OUT"
codesign --force --sign - --entitlements entitlements.plist "$OUT"
echo "==> $OUT"
