#!/usr/bin/env bash
# The battery, run against both architectures.
#
# Cells are chosen to answer the questions experiment 13 could not, because its
# stand-in for a shared kernel was ferry-cri with several containers in a pod —
# an ext4 per container, and so an image cache duplicated per container. With a
# real containerd and overlayfs on the other side, the same questions get honest
# answers:
#
#   idle      what a container costs when it does nothing
#   touch     what it costs once it has read its whole image — the cache question
#   python    the same, with an image big enough for the answer to matter
#
# Counts run past 22, which is where the ferry-cri stand-in stopped being able
# to boot at all.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

SMALL="${SMALL:-ghcr.io/linuxcontainers/alpine:3.20}"
FAT="${FAT:-public.ecr.aws/docker/library/python:3.12}"

cell() { # arch count workload image tag
  echo
  echo "=============== $5 ==============="
  HOLD="${HOLD:-70s}" "$here/bench.sh" "$1" "$2" "$3" "$4" "$5"
}

for n in 8 20; do
  cell vm-per-pod "$n" idle "$SMALL" "idle-alpine-$n-vm-per-pod"
  cell node-vm    "$n" idle "$SMALL" "idle-alpine-$n-node-vm"
done

for n in 8 20; do
  cell vm-per-pod "$n" touch "$SMALL" "touch-alpine-$n-vm-per-pod"
  cell node-vm    "$n" touch "$SMALL" "touch-alpine-$n-node-vm"
done

# The headline: a fat image, eight times over, with and without layer sharing.
HOLD=120s cell vm-per-pod 8 touch "$FAT" "touch-python-8-vm-per-pod"
HOLD=120s cell node-vm    8 touch "$FAT" "touch-python-8-node-vm"

# Past the point where the old stand-in could not boot.
cell node-vm 40 idle "$SMALL" "idle-alpine-40-node-vm"
cell node-vm 40 touch "$SMALL" "touch-alpine-40-node-vm"

"$here/../13-shared-kernel-cost/runtime.sh" stop >/dev/null 2>&1
echo
echo "results in $here/results"
