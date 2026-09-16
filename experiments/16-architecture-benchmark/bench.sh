#!/usr/bin/env bash
# One battery, two architectures.
#
#   vm-per-pod   N pod VMs, one container each      (ferry today)
#   node-vm      1 VM running containerd, N containers   (what mode 2 would be)
#
# Both are given the same image, the same workload, and the same total memory:
# the node VM is configured at N x 512 MiB, which is what the N pod VMs it
# replaces would have had between them. Guest memory is lazily backed, so the
# larger configuration costs nothing it does not touch.
#
# Usage: bench.sh <architecture> <count> <workload> <image> <tag>
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
harness="$here/../13-shared-kernel-cost"
RESULTS="${RESULTS:-$here/results}"
SCRATCH="${SCRATCH:-$here/.scratch}"
mkdir -p "$RESULTS" "$SCRATCH"

arch="$1"; count="$2"; workload="$3"; image="$4"; tag="$5"
hold="${HOLD:-70s}"
# By default the node VM gets what the pod VMs it replaces would have had
# between them. VM_MIB pins it instead, which is what a slope measurement wants:
# hold the intercept still and vary only the number of containers.
mib="${VM_MIB:-$((count * 512))}"

# The outer guest for the node-VM architecture. Not Docker Hub: a battery pulls
# the same image once per cell, and Hub starts answering 429 partway through a
# run, which looks like a benchmark failure and is not one.
OUTER="${OUTER:-public.ecr.aws/docker/library/debian:12}"

# Restarting the runtime resizes pod VMs, but it also drops ferry-cri's image
# cache, so a battery that restarts per cell re-pulls per cell — and every
# public registry starts answering 429 partway through. A caller that keeps the
# VM size constant across a group of cells sets SKIP_RESTART=1 and pays for one
# pull instead of one per cell.
restart_runtime() { # mib
  [ "${SKIP_RESTART:-0}" = 1 ] && return 0
  "$harness/runtime.sh" stop >/dev/null 2>&1
  sleep 3
  POD_MEMORY_MIB="$1" "$harness/runtime.sh" start >/dev/null 2>&1 || {
    echo "runtime failed to start"; exit 1; }
}

case "$arch" in
vm-per-pod)
  # Every pod its own VM, at ferry's own default size.
  restart_runtime 512
  "$harness/build/shkcost" \
    -count "$count" -shape vm-per-pod -workload "$workload" -image "$image" \
    -hold "$hold" -sample 20s -state shk-cri-state \
    -out "$RESULTS/$tag.json"
  ;;
node-vm)
  # One VM, containerd inside it, N containers on overlayfs. Debian rather than
  # Alpine because containerd's release binaries want glibc.
  restart_runtime "$mib"
  script="$SCRATCH/node-vm-$tag.sh"
  {
    echo "BENCH_COUNT=$count"
    echo "BENCH_IMAGE=$image"
    echo "BENCH_WORKLOAD=$workload"
    echo "export BENCH_COUNT BENCH_IMAGE BENCH_WORKLOAD"
    cat "$here/node-vm.sh"
  } >"$script"
  "$harness/build/shkcost" \
    -count 1 -shape vm-per-pod -workload custom -privileged \
    -image "$OUTER" \
    -cmd-file "$script" \
    -mount "$here/stage:/opt/bench" \
    -log-grep "=" \
    -hold "$hold" -sample 20s -state shk-cri-state \
    -out "$RESULTS/$tag.json"
  ;;
*)
  echo "unknown architecture $arch"; exit 2 ;;
esac
