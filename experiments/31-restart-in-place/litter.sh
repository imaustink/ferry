#!/usr/bin/env bash
# Runs litter.yaml and samples, every 15s, how often the litterer has restarted
# and how much of the pod's scratch disk is allocated on the Mac.
#   litter.sh [samples]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
state="$("$here/../../ferry" profile | awk '$1 == "runtime" { print $2 }')/cri"
samples=${1:-9}
kubectl apply -f "$here/litter.yaml" >/dev/null
for i in $(seq 1 "$samples"); do
  sleep 15
  restarts=$(kubectl get pod litter -o json | python3 -c '
import json, sys
p = json.load(sys.stdin)
print(next(c["restartCount"] for c in p["status"]["containerStatuses"] if c["name"] == "litter"))')
  mib=$(du -m "$state"/*-scratch.ext4 | awk '{ s += $1 } END { print s }')
  echo "t=$((i * 15))s restarts=$restarts scratch-allocated=${mib}MiB"
done
kubectl delete pod litter --wait=false >/dev/null
