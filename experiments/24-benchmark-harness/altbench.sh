#!/usr/bin/env bash
# Alternating A/B. The host drifts -- memory pressure over a long session moves
# burst times by more than the difference being measured -- so the only honest
# comparison interleaves the two stacks instead of running one after the other.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
F="${F:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/ferry}"
ROUNDS="${1:-3}"
sub=80
m2_burst() {
  sub=$((sub+1))
  FERRY_MACHINE_SUBNET="192.168.$sub.0/24" "$F" up >/dev/null 2>&1
  FERRY_MACHINE_SUBNET="192.168.$sub.0/24" "$F" machines enable >/dev/null 2>&1
  kc=$("$F" kubeconfig)
  kubectl --kubeconfig "$kc" apply -f - >/dev/null 2>&1 <<YAML
apiVersion: ferry.dev/v1alpha1
kind: Machine
metadata: {name: alt$sub}
spec: {cpus: 10, memory: 15Gi}
YAML
  for _ in $(seq 1 300); do
    [ "$(kubectl --kubeconfig "$kc" get node "alt$sub" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] && break; sleep 1
  done
  export NODE_SELECTOR=$'      nodeSelector: {ferry.dev/mode: shared}\n'
  bash "$here/curve.sh" ferry2 1 >/dev/null 2>&1
  r=$(bash "$here/curve.sh" ferry2 20 2>&1 | grep "20 running" | awk '{print $1}')
  unset NODE_SELECTOR
  "$F" down --purge >/dev/null 2>&1
  echo "$r"
}
kind_burst() {
  kind create cluster --name bench --kubeconfig "$here/kubeconfigs/kind.yaml" >/dev/null 2>&1
  bash "$here/curve.sh" kind 1 >/dev/null 2>&1
  r=$(bash "$here/curve.sh" kind 20 2>&1 | grep "20 running" | awk '{print $1}')
  kind delete cluster --name bench --kubeconfig "$here/kubeconfigs/kind.yaml" >/dev/null 2>&1
  echo "$r"
}
freemem(){ vm_stat | awk '/Pages free/{gsub(/[ .]/,"",$3); printf "%.1fG", $3*16384/1e9}'; }
"$F" down --purge >/dev/null 2>&1; sleep 5
for i in $(seq 1 "$ROUNDS"); do
  a=$(m2_burst); echo "round $i  mode2 $a   (free $(freemem))"
  b=$(kind_burst); echo "round $i  kind  $b   (free $(freemem))"
done
