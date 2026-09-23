#!/usr/bin/env bash
# Footprint against the VM's shape -- configured memory and vCPUs -- for each
# kernel named on the command line (label=path).
#   matrix-shape.sh stock=../../kernel/vmlinux-arm64 nonrot=build/vmlinux-nonrot
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
for spec in "$@"; do
  k=${spec%%=*} kp=${spec#*=}
  for mem in ${MEMS:-256 512 1024 2048 4096}; do
    echo "$k mem=$mem cpu=2: $(KERNEL=$kp POD_MEMORY_MIB=$mem HOLD=15s "$here/measure.sh" "shape-$k-mem$mem-cpu2" 4 idle | grep footprint)"
  done
  for cpu in ${CPUS:-1 4 8}; do
    echo "$k mem=512 cpu=$cpu: $(KERNEL=$kp POD_CPUS=$cpu HOLD=15s "$here/measure.sh" "shape-$k-mem512-cpu$cpu" 4 idle | grep footprint)"
  done
done
