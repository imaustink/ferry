#!/usr/bin/env bash
# Cold sequential reads from an image disk, ROUNDS pods, read-ahead order
# rotated each round. Before each pod the image's ext4 is replaced by an APFS
# clone of itself: the same blocks on the SSD, but a new file, so nothing of
# it is in the Mac's cache. IMAGE is an image with a 2 GiB /big.
#   seq-cold.sh [ROUNDS]
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
STATE="${STATE:-${TMPDIR:-/tmp}/e36-cri-state}"
export IMAGE="${IMAGE:-127.0.0.1:25136/e36/big:2}"
ras=(128 1024 2048 4096 8192)
for r in $(seq 0 $(( ${1:-5} - 1 ))); do
  order=("${ras[@]:r%5}" "${ras[@]:0:r%5}")
  sed "s/ORDER/${order[*]}/" "$here/probe-cold.sh" > "$here/build/probe-cold-$r.sh"
  # The largest image ext4 in the state directory is the one with /big in it.
  img=$(ls -S "$STATE"/image-sha256_*.ext4 2>/dev/null | head -1)
  if [ -n "$img" ] && [ "$(stat -f %z "$img")" -gt 3000000000 ]; then
    cp -c "$img" "$img.clone" && mv "$img.clone" "$img"
  fi
  HOLD=25s TRACE_LINES=1 "$here/probe-at.sh" "seq-cold-$r" "build/probe-cold-$r.sh" 1 | grep "pass="
done
