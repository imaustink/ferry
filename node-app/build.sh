#!/usr/bin/env bash
# Build the app's Linux image with buildkit in a ferry pod -- no Docker
# daemon anywhere.
#
#   ./build.sh                 # -> image node-app:1, ready for manifests/
#
# ferry image build needs only buildctl (`brew install buildkit`) on the
# Mac; it runs the actual build inside an ephemeral buildkit pod on the
# cluster and loads the result straight into the image store pods are
# served from. Docker Desktop does not have to be installed, let alone
# running. See docs/RUNTIMES.md#building-an-image-without-docker.
set -euo pipefail
cd "$(dirname "$0")"

image="${1:-node-app:1}"

echo "==> ferry image build -t $image ."
ferry image build -t "$image" .

echo "==> built $image"
