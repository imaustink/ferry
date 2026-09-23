#!/usr/bin/env bash
# Two machines (mode 2), then what each one's kubelet certificate may read and
# whether each has a route to the other's pods.
# usage: machines.sh [up|down]   from the checkout, with KUBECONFIG pointing at the cluster (admin)
set -u
here="$(cd "$(dirname "$0")/../.." && pwd)"
if [ "${1:-up}" = down ]; then
  kubectl delete machine e37-m0 e37-m1 --ignore-not-found --wait=true
  "$here/ferry" machines disable
  exit 0
fi
"$here/ferry" machines enable 2>&1 | tail -4
for m in e37-m0 e37-m1; do
  kubectl apply -f - >/dev/null <<YAML
apiVersion: ferry.dev/v1alpha1
kind: Machine
metadata: {name: $m}
spec: {cpus: 2, memory: 2Gi, disk: 8Gi, role: worker}
YAML
done
for _ in $(seq 1 180); do
  ready="$(kubectl get nodes e37-m0 e37-m1 --no-headers 2>/dev/null | grep -c ' Ready ')"
  [ "$ready" = 2 ] && break
  sleep 2
done
kubectl get nodes -o wide | grep -E 'NAME|e37-m'
for m in e37-m0 e37-m1; do
  printf '  %-8s list nodes as itself: %s\n' "$m" \
    "$(kubectl auth can-i list nodes --as="system:node:$m" --as-group=system:nodes 2>&1)"
done
