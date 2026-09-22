#!/usr/bin/env bash
# What it costs to have a builder available at all.
#
# bench.sh's idle-mem is a delta taken across starting buildkitd, and for
# docker and colima that delta is nearly nothing -- 2 MiB in one cell -- which
# is true and deeply misleading. It prices a container inside a virtual machine
# that was already running, and says nothing about the virtual machine, which
# is the thing you actually have to keep for a builder to exist.
#
# So this prices the virtual machine. For each option: the host-side footprint
# of the VM process that has to exist, and what is used inside it.
#
# The first version of this script took host-wide active+wired+compressed
# deltas across starting and stopping each stack, which is the method the
# README's Docker row uses. On this Mac it did not work: the baseline was
# 50.7 GiB of other people's work and the deltas were buried in its movement.
# That method needs a quiet machine; this one does not, and is per-VM, so
# docs/BENCHMARKING.md's rule applies in full --
#
#   ferry's builder VM is small and vmmap resolves it.
#   colima's is allocated at 4 GiB and Docker Desktop's at 15.6 GiB, and
#   vmmap reports the allocation, not the use. Those two are read inside the
#   guest as well, and the in-guest number is the honest one for them.
#
# Both are printed for all three rather than one being picked, because the
# pair is the finding: ferry's builder has no VM-sized floor under it, and
# that is the whole difference.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/lib.sh"

SETTLE="${SETTLE:-20}"

# Docker Desktop's VM, found the way experiment 24's stacks.sh finds it. That
# file is not sourced here because it also brings kind, minikube and a cluster
# name, none of which this experiment has.
docker_vm_pid() {
  local pid
  for pid in $(vm_pids); do
    lsof -p "$pid" 2>/dev/null | grep -qF "com.docker.docker/Data/vms" && { echo "$pid"; return; }
  done
}

colima_vm_pid() {
  local pid
  for pid in $(vm_pids); do
    lsof -p "$pid" 2>/dev/null | grep -qF ".colima/" && { echo "$pid"; return; }
  done
  # colima runs under lima, which on this macOS uses vz but may not show up in
  # the Virtualization.VirtualMachine scan; fall back to the process name.
  pgrep -f 'limactl.*colima|qemu-system-aarch64.*colima' 2>/dev/null | head -1
}

row() { # label host_mib guest_mib note
  printf '  %-26s %10s %10s   %s\n' "$1" "$2" "${3:--}" "${4:-}"
  record cost "$1-host" "$2"
  record cost "$1-guest" "${3:--}"
}

echo "=== what a builder costs to keep available"
printf '  %-26s %10s %10s\n' '' 'host MiB' 'guest MiB'
echo

# ferry: the builder pod is a VM of its own, so the delta across starting it
# is exactly the builder's cost and vmmap can resolve it.
builder_down ferry
sleep "$SETTLE"
before="$(ferry_vm_footprint)"
builder_up ferry >/dev/null 2>&1
sleep "$SETTLE"
after="$(ferry_vm_footprint)"
row ferry-buildkit-pod "$(delta "$after" "$before")" "-" "delta, vmmap resolves it"
builder_down ferry

# docker and colima: the VM has to be there before buildkitd can be, so the VM
# is the cost. Read whole, not as a delta.
if docker --context "$DOCKER_CTX" info >/dev/null 2>&1; then
  builder_up docker >/dev/null 2>&1
  sleep "$SETTLE"
  # It was expected to saturate -- docs/BENCHMARKING.md records vmmap pinned at
  # exactly 14,848.0 MiB for this VM in every phase of every stack. It did not
  # here: it read ~1,740 MiB, next to the README's 1,685 MiB for "Docker before
  # any cluster", which is the same measurement taken independently. Saturation
  # is a function of how much of the allocation has been touched, and a Docker
  # that has only just started and run one container has not touched much.
  row docker-desktop-vm "$(footprint_mib "$(docker_vm_pid)")" "$(guest_used_mib docker)" \
    "agrees with the README's 1,685 MiB"
  builder_down docker
else
  echo "  docker-desktop-vm          (not running)"
fi

if colima status >/dev/null 2>&1; then
  builder_up colima >/dev/null 2>&1
  sleep "$SETTLE"
  row colima-vm "$(footprint_mib "$(colima_vm_pid)")" "$(guest_used_mib colima)" \
    "4 GiB allocated, 1 GiB of it charged"
  builder_down colima
else
  echo "  colima-vm                  (not running)"
fi

echo
echo "results in $RESULTS/raw.tsv"
