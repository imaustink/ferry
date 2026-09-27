#!/usr/bin/env bash
# Builds demo/Dockerfile -- a COPY, three RUN steps (one of which runs the
# previous RUN's own output), and an ENTRYPOINT -- into a real OCI layout,
# entirely through a macOS VM cloned from experiment 39's golden bundle.
#
#   ./run-demo.sh [path/to/experiments/39-macos-pods/.cache/golden]
#
# Needs ./build.sh to have run once, and experiment 39's golden bundle to
# exist (its README/FINDINGS.md cover building one).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

golden="${1:-$here/../39-macos-pods/.cache/golden}"
[[ -d "$golden" ]] || { echo "run-demo.sh: no golden bundle at $golden" >&2; exit 1; }
[[ -x build/macvm ]] || { echo "run-demo.sh: build/macvm is missing -- run ./build.sh" >&2; exit 1; }
[[ -x mkimage-run/mkimage-run ]] || { echo "run-demo.sh: mkimage-run is missing -- run ./build.sh" >&2; exit 1; }

out="$(mktemp -d "${TMPDIR:-/tmp}/ferry-mac-build-demo.XXXXXX")"
trap 'rm -rf "$out"' EXIT

./mkimage-run/mkimage-run \
  -name example.com/hello-darwin:1 \
  -out "$out/layout" \
  -f demo/Dockerfile \
  -context demo \
  -golden "$golden" \
  -macvm ./build/macvm

echo
echo "==> OCI layout written to a temp dir and discarded; layer contents:"
manifest="$(python3 -c "
import json
print(json.load(open('$out/layout/index.json'))['manifests'][0]['digest'].split(':')[1])
")"
layer="$(python3 -c "
import json
print(json.load(open('$out/layout/blobs/sha256/$manifest'))['layers'][0]['digest'].split(':')[1])
")"
tar -tzvf "$out/layout/blobs/sha256/$layer"
