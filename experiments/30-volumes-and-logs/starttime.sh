#!/usr/bin/env bash
# Pod start time: kubectl apply to Ready, N times per variant, one at a time.
#   ./starttime.sh [N] [variant...]   variants: plain emptydir memory
set -euo pipefail
N=${1:-5}; shift || true
variants=${*:-plain emptydir memory}
now() { python3 -c 'import time; print(time.time())'; }
pod() {
  local name=$1 variant=$2 vol="" mnt=""
  case $variant in
    emptydir) vol='  volumes: [{name: scratch, emptyDir: {}}]'
              mnt='    volumeMounts: [{name: scratch, mountPath: /scratch}]' ;;
    memory)   vol='  volumes: [{name: scratch, emptyDir: {medium: Memory, sizeLimit: 64Mi}}]'
              mnt='    volumeMounts: [{name: scratch, mountPath: /scratch}]' ;;
  esac
  cat <<YAML
apiVersion: v1
kind: Pod
metadata: {name: $name}
spec:
  terminationGracePeriodSeconds: 0
  containers:
  - name: c
    image: alpine:3.20
    command: [sleep, "3600"]
$mnt
$vol
YAML
}
kubectl delete pod warm --ignore-not-found --wait >/dev/null
kubectl run warm --image=alpine:3.20 --restart=Never -- true >/dev/null
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/warm --timeout=180s >/dev/null
kubectl delete pod warm --wait >/dev/null
for variant in $variants; do
  for i in $(seq 1 "$N"); do
    name="st-$variant-$i"
    t0=$(now)
    pod "$name" "$variant" | kubectl apply -f - >/dev/null
    kubectl wait --for=condition=Ready "pod/$name" --timeout=120s >/dev/null
    t1=$(now)
    python3 -c "print('$variant', $i, round($t1 - $t0, 2))"
    kubectl delete pod "$name" --wait >/dev/null
  done
done
