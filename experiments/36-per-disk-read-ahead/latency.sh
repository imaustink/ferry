#!/usr/bin/env bash
# Cold pod start, one pod at a time, before and after, alternating so drift in
# the machine lands on both. BEFORE is the runtime without per-disk read-ahead.
#   latency.sh [reps]
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
SHK="$here/build/shkcost"
BEFORE="${BEFORE:-$here/build/ferry-cri-before}"
run() { # cri
  CRI=$1 "$here/runtime.sh" start >/dev/null || return 1
  "$SHK" -endpoint /tmp/e36-cri.sock -count 1 -workload idle -hold 1s -sample 1s \
    -state e36-cri-state 2>&1 | awk '/containers running in/ {print $NF}'
  "$here/runtime.sh" stop >/dev/null
}
b=() a=()
for _ in $(seq 1 "${1:-10}"); do
  b+=("$(run "$BEFORE")")
  a+=("$(run "$here/../../bin/ferry-cri")")
done
echo "before: ${b[*]}"
echo "after:  ${a[*]}"
python3 - "${b[*]}" "${a[*]}" <<'EOF'
import sys, statistics
def ms(v): return float(v[:-2]) if v.endswith("ms") else float(v[:-1]) * 1000
for name, s in zip(("before", "after"), sys.argv[1:]):
    xs = [ms(v) for v in s.split()]
    print(f"{name} median {statistics.median(xs):.0f} ms  min {min(xs):.0f}  max {max(xs):.0f}")
EOF
