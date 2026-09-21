#!/usr/bin/env bash
# Alternating A/B, because the numbers taken minutes apart disagreed.
#
# ferry's first pod read 705ms in one run and 892ms in another with strictly
# less work to do, which no causal story explains -- so the host moved between
# them. docs/BENCHMARKING.md: alternate the stacks and repeat rounds, and log
# free memory beside each sample so drift is visible in the output.
set -uo pipefail
cd "$(dirname "$0")"
H=experiments/24-benchmark-harness
FK=/Users/austinkurpuis/.ferry-performance-tuning/admin.conf
KK="$HOME/.kube/config-perfk"

freemem() { vm_stat | awk '/Pages free/{gsub(/[ .]/,"",$3); printf "%.1fG", $3*16384/1e9}'; }
grab() { grep -E '^  (first|last)' | tr -s ' ' | cut -d' ' -f2-3 | tr '\n' ' '; }

for i in 1 2 3; do
  a=$(python3 "$H/burst.py" "$FK" ferry.dev/mode=shared 20 1 2>/dev/null | grab)
  echo "round $i  ferry  $a  (free $(freemem))"
  b=$(python3 "$H/burst.py" "$KK" - 20 1 2>/dev/null | grab)
  echo "round $i  kind   $b  (free $(freemem))"
done
