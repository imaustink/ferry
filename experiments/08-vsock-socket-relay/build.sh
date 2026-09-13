#!/usr/bin/env bash
# Builds the probe and signs it. Virtualization.framework refuses to start a VM
# without the entitlement, so the binary is ad-hoc signed after linking.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"
swift build -c release
# Copy first, then sign the copy. Signing the build-directory binary and then
# copying it has produced binaries that are killed on launch; signing the final
# path is reliable.
cp "$(swift build -c release --show-bin-path)/relayprobe" ./relayprobe
codesign --force --sign - --entitlements entitlements.plist ./relayprobe
echo "==> $here/relayprobe"
