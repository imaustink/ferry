#!/usr/bin/env bash
# `swift test` for one of ferry's Swift packages, working with the Command
# Line Tools alone.
#
# The tests use swift-testing, whose macros live in a compiler plugin. Xcode's
# toolchain finds it; the Command Line Tools ship it too, under
# usr/lib/swift/host/plugins/testing, but SwiftPM does not look there, and the
# build fails with "plugin for module 'TestingMacros' not found". So when the
# active developer directory is the Command Line Tools, the plugin and the
# Testing framework are named explicitly.
#
#   tests/swift.sh <package directory> [swift test args...]
set -euo pipefail
package="$1"; shift
SWIFT="${SWIFT:-swift}"
flags=()
dev="$(xcode-select -p 2>/dev/null || true)"
case "$dev" in
  */CommandLineTools)
    plugins="$dev/usr/lib/swift/host/plugins/testing"
    frameworks="$dev/Library/Developer/Frameworks"
    if [ -d "$plugins" ] && [ -d "$frameworks" ]; then
      flags=(-Xswiftc -plugin-path -Xswiftc "$plugins"
             -Xswiftc -F -Xswiftc "$frameworks"
             -Xlinker -rpath -Xlinker "$frameworks")
    fi ;;
esac
cd "$package"
exec "$SWIFT" test ${flags[@]+"${flags[@]}"} "$@"
