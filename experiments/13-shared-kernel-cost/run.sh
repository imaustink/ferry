#!/usr/bin/env bash
# The matrix. Every cell is the same containers doing the same work; the only
# thing that changes is whether each one gets its own kernel.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

RESULTS="${RESULTS:-$here/results}"
mkdir -p "$RESULTS"
SHK="$here/build/shkcost"
SMALL="${SMALL:-ghcr.io/linuxcontainers/alpine:3.20}"
FAT="${FAT:-docker.io/library/python:3.12}"

cell() { # shape count workload image hold tag
  local shape=$1 count=$2 workload=$3 image=$4 hold=$5 tag=$6
  echo
  echo "=============== $tag ==============="
  "$SHK" -shape "$shape" -count "$count" -workload "$workload" -image "$image" \
    -hold "$hold" -sample 5s -state shk-cri-state -out "$RESULTS/$tag.json"
  # A vmnet address is held for about a minute after the pod using it stops, so
  # give the next cell a moment rather than starving it of addresses.
  sleep 5
}

for n in 8 20; do
  cell vm-per-pod "$n" idle "$SMALL" 20s "idle-alpine-$n-vm-per-pod"
  cell shared-vm  "$n" idle "$SMALL" 20s "idle-alpine-$n-shared-vm"
done

for n in 8 20; do
  cell vm-per-pod "$n" touch "$SMALL" 30s "touch-alpine-$n-vm-per-pod"
  cell shared-vm  "$n" touch "$SMALL" 30s "touch-alpine-$n-shared-vm"
done

cell vm-per-pod 8 touch "$FAT" 90s "touch-python-8-vm-per-pod"
cell shared-vm  8 touch "$FAT" 90s "touch-python-8-shared-vm"

cell vm-per-pod 8 reread "$SMALL" 45s "reread-alpine-8-vm-per-pod"
cell shared-vm  8 reread "$SMALL" 45s "reread-alpine-8-shared-vm"

echo
echo "results in $RESULTS"
