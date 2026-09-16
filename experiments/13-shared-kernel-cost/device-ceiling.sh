#!/usr/bin/env bash
# How many containers fit in one VM?
#
# Not a memory question: ferry gives every container its own cloned ext4, so a
# pod with N containers is a VM with N block devices, and Virtualization.framework
# has a limit on those. Finds where it is by walking up until a VM refuses to
# boot. The runtime is restarted between attempts because a failed boot leaves
# the sandbox behind.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

SHK="$here/build/shkcost"
IMAGE="${IMAGE:-ghcr.io/linuxcontainers/alpine:3.20}"

for n in "$@"; do
  ./runtime.sh stop >/dev/null 2>&1
  sleep 3
  POD_MEMORY_MIB=$((n * 512)) ./runtime.sh start >/dev/null 2>&1
  if "$SHK" -shape shared-vm -count "$n" -workload idle -image "$IMAGE" \
      -hold 3s -sample 3s -state shk-cri-state >/dev/null 2>&1; then
    echo "$n containers in one VM: ok"
  else
    echo "$n containers in one VM: FAILED to boot"
  fi
done

./runtime.sh stop >/dev/null 2>&1
sleep 3
./runtime.sh start >/dev/null 2>&1
echo "done"
