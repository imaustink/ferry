#!/usr/bin/env bash
# Runs fanout.sh and reads ferry-cri's trace (FERRY_CRI_TRACE=1) for what the
# runtime itself spent: the StartContainer that booted the VM, and every
# CreateContainer summed.
#   boot-cost.sh <containers> [runs]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
log="${FERRY_CRI_LOG:-$("$here/../../ferry" profile | awk '$1 == "runtime" { print $2 }')/logs/ferry-cri.log}"
n=${1:-8}
runs=${2:-3}
for _ in $(seq 1 "$runs"); do
  before=$(wc -l < "$log")
  "$here/fanout.sh" "$n" >/dev/null
  tail -n +"$((before + 1))" "$log" | awk -v n="$n" '
    / trace +create / { sub("ms", "", $NF); create += $NF }
    / trace +start /  { sub("ms", "", $NF); if ($NF + 0 > boot) boot = $NF + 0 }
    END { printf "containers=%d boot-start=%dms creates=%dms\n", n, boot, create }'
done
