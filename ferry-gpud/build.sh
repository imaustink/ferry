#!/usr/bin/env bash
# No entitlement: ferry-gpud does not create VMs. It talks to Metal and the
# on-device model, which any process may do.
#
# It still has to be signed. Every binary on Apple silicon carries at least an
# ad-hoc signature, and copying over an existing file invalidates it -- the
# symptom is "Killed: 9" at launch with no other explanation. So remove the
# target first, then sign the final path, the same way the other build scripts
# here do.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"
swift build -c release
mkdir -p ../bin
rm -f ../bin/ferry-gpud
cp "$(swift build -c release --show-bin-path)/ferry-gpud" ../bin/ferry-gpud
codesign --force --sign - ../bin/ferry-gpud
echo "==> $(cd .. && pwd)/bin/ferry-gpud"
