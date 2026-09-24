#!/usr/bin/env bash
# One cell: a fresh ferry-cri, COUNT pods of WORKLOAD, held and measured by
# experiment 13's CRI client, then torn down. Results land in results/LABEL.json.
#   measure.sh LABEL COUNT WORKLOAD [shkcost flags...]
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
label=$1 count=$2 workload=$3; shift 3
SHK="${SHK:-$here/build/shkcost}"
[ -x "$SHK" ] || (cd "$here/../13-shared-kernel-cost" && go build -o "$SHK" .) || exit 1
mkdir -p "$here/results"
"$here/runtime.sh" stop >/dev/null
"$here/runtime.sh" start || exit 1
"$SHK" -endpoint /tmp/e36-cri.sock -count "$count" -workload "$workload" \
  -hold "${HOLD:-30s}" -sample 10s -state e36-cri-state \
  -out "$here/results/$label.json" "$@" 2>&1 | grep -vE "stdout F P\|"
"$here/runtime.sh" stop >/dev/null
