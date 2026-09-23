#!/usr/bin/env bash
# N idle pods through the whole cluster -- kubelet, scheduler, CNI -- on this
# checkout's running ferry: time until all are Running, then what their VMs
# cost. Run after `ferry up`.
#   cluster-density.sh N LABEL
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
n=$1 label=$2
root="$(cd "$here/../.." && pwd)"
profile="$(basename "$root")"
export KUBECONFIG="${KUBECONFIG:-$HOME/.ferry-$profile/admin.conf}"
kubectl delete deploy idle --ignore-not-found --wait=true >/dev/null
start=$(python3 -c 'import time;print(time.time())')
kubectl create deploy idle --image=alpine:3.20 --replicas="$n" -- sh -c 'sleep 100000' >/dev/null
until [ "$(kubectl get pods -l app=idle --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')" -ge "$n" ]; do sleep 0.5; done
took=$(python3 -c "import time;print(f'{time.time()-$start:.1f}')")
sleep 20
fp="$(STATE="ferry-run-$profile" "$here/vms.sh" footprint | tail -1)"
echo "$label n=$n all Running in ${took}s; $fp" | tee -a "$here/results/cluster-density.txt"
kubectl delete deploy idle --wait=false >/dev/null
