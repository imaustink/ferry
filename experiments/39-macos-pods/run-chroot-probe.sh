#!/usr/bin/env bash
# Boots a pod from a golden image and runs chroot-probe.sh inside it, with a
# locally built binary standing in for an image's contents.
#
#   ./run-chroot-probe.sh [golden] [--same-id]
#   PROBE=shared-region-why.sh ./run-chroot-probe.sh ...     another guest script
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
golden="${1:-$here/.cache/golden}"
shift || true
clang -O2 -o "$here/build/hello" "$here/hello.c"
exec "$here/build/macvm" pod "$golden" "$here/.cache/pod-chroot" "$@" -- \
    /bin/sh -c "$(cat "$here/${PROBE:-chroot-probe.sh}")" probe "$(base64 -i "$here/build/hello")"
