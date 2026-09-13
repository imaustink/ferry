#!/usr/bin/env bash
# No entitlement: this talks to Metal and the on-device model, which any process
# may do. It still needs a valid signature after being copied -- see
# ferry-gpud/build.sh for why.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"
SWIFT="${SWIFT:-swift}"
"$SWIFT" build -c release
rm -f ./contention
cp "$("$SWIFT" build -c release --show-bin-path)/contention" ./contention
codesign --force --sign - ./contention
echo "==> $here/contention"
