#!/usr/bin/env bash
# Rebuilds just the tool, for when the image has not changed.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"
SWIFT="${SWIFT:-swift}"
"$SWIFT" build -c release
cp "$("$SWIFT" build -c release --show-bin-path)/ferry-node" build/ferry-node
codesign --force --sign - --entitlements entitlements.plist build/ferry-node
echo "==> $here/build/ferry-node"
