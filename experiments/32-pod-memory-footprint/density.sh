#!/usr/bin/env bash
# Many idle pods at once, before and after: the per-pod cost where it counts,
# and the time to get them all running.
#   density.sh "20 60"
# BEFORE_CRI is the runtime without this experiment's changes (the main
# checkout's build of the same base commit), on the kernel ferry shipped.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
BEFORE_CRI="${BEFORE_CRI:-$here/build/ferry-cri-before}"
BEFORE_KERNEL="${BEFORE_KERNEL:-$here/build/vmlinux-before}"
AFTER_KERNEL="${AFTER_KERNEL:-$here/../../kernel/vmlinux-arm64}"
for n in ${1:-20 60}; do
  echo "before n=$n: $(CRI=$BEFORE_CRI KERNEL=$BEFORE_KERNEL HOLD=20s "$here/measure.sh" "density-before-$n" "$n" idle | grep -E 'footprint|time to running' | tr -s ' ' | tr '\n' ' ')"
  sleep 60   # vmnet holds an address for about a minute after its pod stops
  echo "after  n=$n: $(KERNEL=$AFTER_KERNEL HOLD=20s "$here/measure.sh" "density-after-$n" "$n" idle | grep -E 'footprint|time to running' | tr -s ' ' | tr '\n' ' ')"
  sleep 60
done
