#!/usr/bin/env bash
# The VM processes that belong to this experiment -- the ones holding a file
# under its state directory -- and what macOS charges each of them.
#   vms.sh pids        one pid per line
#   vms.sh footprint   pid, phys_footprint MiB, rss MiB
#   vms.sh detail      footprint(1)'s per-region breakdown of the first VM
set -uo pipefail
STATE="${STATE:-${TMPDIR:-/tmp}/e32-cri-state}"
mine() {
  for pid in $(pgrep -f Virtualization.VirtualMachine); do
    lsof -p "$pid" -Fn 2>/dev/null | grep -q "$(basename "$STATE")" && echo "$pid"
  done
}
case "${1:-footprint}" in
pids) mine ;;
footprint)
  total=0; n=0
  for pid in $(mine); do
    fp=$(footprint -p "$pid" 2>/dev/null | awk '/phys_footprint:/ {v=$2; u=$3; if (u=="KB") v/=1024; if (u=="GB") v*=1024; print v; exit}')
    rss=$(ps -o rss= -p "$pid" | awk '{print $1/1024}')
    echo "$pid $fp $rss"
    total=$(echo "$total + $fp" | bc); n=$((n+1))
  done
  [ "$n" -gt 0 ] && echo "TOTAL n=$n footprint=$total MiB per_vm=$(echo "scale=1; $total / $n" | bc)" ;;
detail) footprint -p "$(mine | head -1)" ;;
esac
