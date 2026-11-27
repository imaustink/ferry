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
# The Command Line Tools have no Developer/usr/lib or Developer/Library/Frameworks,
# and SwiftPM passes both to the linker anyway: two "search path not found"
# warnings per product on every build, about nothing. Only those two go.
"$SWIFT" build -c release 2>&1 \
  | { grep -v "ld: warning: search path '/Library/Developer/CommandLineTools/Developer/[^']*' not found$" || true; }
rm -f "$OUT"
cp "$("$SWIFT" build -c release --show-bin-path)/ferry-node" "$OUT"
codesign --force --sign - --entitlements entitlements.plist "$OUT"
echo "==> $OUT"
