#!/usr/bin/env bash
# Where do the battery's pods actually land under ferry2?
#
# run.sh interpolates ${NODE_SELECTOR:-} into its Deployment, and stacks.sh
# never sets it for the ferry2 case. With mode 2 on there are two nodes -- the
# Mac (mode 1, a pod is a VM) and the machine (mode 2, a pod is a container) --
# so an unpinned pod can go to either. If it goes to both, the battery's ferry2
# latency rows are a mixture of the two architectures rather than a measurement
# of mode 2.
set -uo pipefail
cd "$(dirname "$0")"
kc="$(./ferry kubeconfig)"
N="${N:-10}"

KUBECONFIG="$kc" kubectl create namespace whereland >/dev/null 2>&1
KUBECONFIG="$kc" kubectl -n whereland delete deployment bench --ignore-not-found >/dev/null 2>&1
sleep 3

# Exactly the shape run.sh builds, with NODE_SELECTOR unset -- as the battery
# leaves it for ferry2.
KUBECONFIG="$kc" kubectl apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: bench, namespace: whereland}
spec:
  replicas: $N
  selector: {matchLabels: {app: bench}}
  template:
    metadata: {labels: {app: bench}}
    spec:
      terminationGracePeriodSeconds: 0
      containers:
      - name: c
        image: alpine:3.20
        command: ["sleep", "3600"]
YAML

for _ in $(seq 1 180); do
  r=$(KUBECONFIG="$kc" kubectl -n whereland get pods --no-headers 2>/dev/null | awk '$3=="Running"' | wc -l | tr -d ' ')
  [ "${r:-0}" -ge "$N" ] && break
  sleep 1
done

echo "== $N unpinned pods, exactly the battery's manifest"
KUBECONFIG="$kc" kubectl -n whereland get pods -o custom-columns=NODE:.spec.nodeName --no-headers \
  | sort | uniq -c | sed 's/^/  /'
echo "== what those nodes are"
KUBECONFIG="$kc" kubectl get nodes -L ferry.dev/mode --no-headers | sed 's/^/  /'

KUBECONFIG="$kc" kubectl -n whereland delete deployment bench --wait=false >/dev/null 2>&1
