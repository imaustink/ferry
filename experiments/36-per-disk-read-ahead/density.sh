#!/usr/bin/env bash
# Many idle pods at once, before and after: the per-pod cost where it counts,
# and the time to get them all running. Then, from the after run's trace, how
# long each boot waited on the read-ahead writes once its containers were in.
#   density.sh "20"
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
STATE="${STATE:-${TMPDIR:-/tmp}/e36-cri-state}"
BEFORE="${BEFORE:-$here/build/ferry-cri-before}"
for n in ${1:-20}; do
  echo "before n=$n: $(CRI=$BEFORE HOLD=20s "$here/measure.sh" "density-before-$n" "$n" idle | grep -E 'footprint|time to running' | tr -s ' ' | tr '\n' ' ')"
  sleep 60   # vmnet holds an address for about a minute after its pod stops
  echo "after  n=$n: $(FERRY_CRI_TRACE=1 HOLD=20s "$here/measure.sh" "density-after-$n" "$n" idle | grep -E 'footprint|time to running' | tr -s ' ' | tr '\n' ' ')"
  grep -h "trace     boot" "$STATE/ferry-cri.log" | python3 -c '
import re, statistics, sys
waits = [int(r) - int(a) for a, r in (re.search(r"add=(\d+)ms readahead=(\d+)ms", l).groups() for l in sys.stdin)]
print(f"  read-ahead wait after add, ms: median {statistics.median(waits)} max {max(waits)} n={len(waits)}")'
  sleep 60
done
