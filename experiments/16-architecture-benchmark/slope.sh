#!/usr/bin/env bash
# What does the Nth container actually cost?
#
# Totals mislead here. The node VM carries fixed costs the pod VMs do not — a
# guest OS, containerd, and an image store inside the guest — while vm-per-pod
# carries a kernel per pod and nothing fixed. Comparing totals at one count
# compares intercepts as much as slopes.
#
# The slope is the architectural claim. With layer sharing, the Nth container
# reading the same image costs only its private pages; without it, the Nth costs
# another copy of the image. Experiment 13 measured that slope at 1267 MiB per
# container for ferry-cri's ext4-per-container shape — no sharing at all. This
# measures it for a real containerd on overlayfs.
#
# Each architecture's runtime is started once and held across its whole series:
# the node VM stays one fixed size so the intercept does not move, and ferry-cri
# keeps its image cache so the series costs one pull rather than one per cell.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
harness="$here/../13-shared-kernel-cost"

IMAGE="${IMAGE:-docker.io/library/python:3.12-slim}"
WORKLOAD="${WORKLOAD:-touch}"
COUNTS="${COUNTS:-1 2 4 8}"

echo "==> node-vm series (VM pinned at 6144 MiB)"
"$harness/runtime.sh" stop >/dev/null 2>&1
sleep 3
POD_MEMORY_MIB=6144 "$harness/runtime.sh" start >/dev/null 2>&1
for n in $COUNTS; do
  echo
  echo "=============== slope-python-$n-node-vm ==============="
  SKIP_RESTART=1 HOLD=100s "$here/bench.sh" node-vm "$n" "$WORKLOAD" "$IMAGE" "slope-python-$n-node-vm"
done

echo "==> vm-per-pod series (512 MiB per pod)"
"$harness/runtime.sh" stop >/dev/null 2>&1
sleep 3
POD_MEMORY_MIB=512 "$harness/runtime.sh" start >/dev/null 2>&1
for n in $COUNTS; do
  echo
  echo "=============== slope-python-$n-vm-per-pod ==============="
  SKIP_RESTART=1 HOLD=100s "$here/bench.sh" vm-per-pod "$n" "$WORKLOAD" "$IMAGE" "slope-python-$n-vm-per-pod"
done

"$harness/runtime.sh" stop >/dev/null 2>&1
echo "slope results in $here/results"
