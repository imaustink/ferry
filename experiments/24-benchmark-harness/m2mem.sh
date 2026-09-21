#!/usr/bin/env bash
# Mode 2's per-pod memory, read where mode 2 actually keeps it.
#
# summarize.py charges ferry2 the node VM's phys_footprint, which also carries
# guest page cache -- the same objection its docstring raises against using
# Docker's host-side RSS for kind. For a stack whose pods are containers in one
# guest, the honest number is used memory inside that guest, so this reads it
# the same way docker_guest_used_mib does: a container in the guest, reporting
# the guest's own /proc/meminfo.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/stacks.sh"

kc=""
guest_used() { # MiB used inside the node VM
  KUBECONFIG="$kc" kubectl run memprobe-$RANDOM --rm -i --restart=Never \
    --image=alpine:3.20 --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"worker-0"}}}' \
    -- free -m 2>/dev/null | awk '/^Mem:/{print $2-$7}'
}

echo "==> bringing mode 2 up"
stack_up ferry2
kc=$("$FERRY" kubeconfig)
wait_ready "$kc" "" 600 || { echo "not ready"; exit 1; }
KUBECONFIG="$kc" kubectl create namespace bench >/dev/null 2>&1

echo "==> warming the image cache"
NODE_SELECTOR='      nodeSelector: {kubernetes.io/hostname: worker-0}
'
warm=$(guest_used); echo "    (probe image cached)"

sleep 30
echo "idle            $(guest_used) MiB used in guest"

for n in 10 20; do
  cat > /tmp/m2mem-$n.yaml <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: bench, namespace: bench}
spec:
  replicas: $n
  selector: {matchLabels: {app: bench}}
  template:
    metadata: {labels: {app: bench}}
    spec:
      terminationGracePeriodSeconds: 0
      nodeSelector: {kubernetes.io/hostname: worker-0}
      containers:
      - name: c
        image: alpine:3.20
        command: ["sleep", "3600"]
YAML
  KUBECONFIG="$kc" kubectl apply -f /tmp/m2mem-$n.yaml >/dev/null 2>&1
  for _ in $(seq 1 120); do
    r=$(KUBECONFIG="$kc" kubectl get pods -n bench --no-headers 2>/dev/null | awk '$3=="Running"' | wc -l | tr -d ' ')
    [ "${r:-0}" -ge "$n" ] && break; sleep 1
  done
  sleep 20
  echo "$n pods         $(guest_used) MiB used in guest"
  KUBECONFIG="$kc" kubectl delete deployment bench -n bench --wait=true >/dev/null 2>&1
  sleep 15
done

echo "==> tearing down"
stack_down ferry2
