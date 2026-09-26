#!/usr/bin/env bash
# macOS machines on demand. Nothing is declared: a pod that asks for macOS
# causes a macOS machine, the third one waits for a macOS guest slot, and
# machines with nothing on them are taken away.
#
#   1. one replica                -> one macOS machine, made by Karpenter
#   2. three replicas of 6 GiB    -> a second machine, and the third pod Pending,
#                                    because the Mac runs two macOS guests
#   3. zero replicas              -> the machines go
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
state=$("$here/../../ferry" profile | awk '$1 == "state" {print $2}')
export KUBECONFIG="$state/admin.conf"
k() { kubectl "$@"; }
img=example.com/podsrv-darwin:3
t0=$(date +%s)
el() { echo "$(( $(date +%s) - t0 )) s"; }
show() {
    k get nodeclaims -o custom-columns=CLAIM:.metadata.name,TYPE:.metadata.labels.node\\.kubernetes\\.io/instance-type,READY:.status.conditions[-1].status 2>&1 | sed 's/^/    /'
    k get machines 2>&1 | sed 's/^/    /'
    k get nodes -L ferry.dev/mode 2>&1 | sed 's/^/    /'
    k get pods -l app=auto -o wide 2>&1 | sed 's/^/    /'
}
running() { k get pods -l app=auto -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' | grep -c Running; }

k delete machine --all --timeout=120s >/dev/null 2>&1
k apply -f - >/dev/null <<EOF
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata: {name: ferry-macos-shared, labels: {experiment: "39"}}
handler: ferry-darwin
scheduling:
  nodeSelector: {ferry.dev/mode: shared-macos}
  tolerations: [{key: ferry.dev/mode, operator: Equal, value: shared-macos, effect: NoSchedule}]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: auto, labels: {experiment: "39"}}
spec:
  replicas: 1
  selector: {matchLabels: {app: auto}}
  template:
    metadata: {labels: {app: auto}}
    spec:
      runtimeClassName: ferry-macos-shared
      containers:
        - name: web
          image: $img
          args: [serve, auto]
          resources: {requests: {cpu: 500m, memory: 512Mi}}
EOF
echo "=== 1. one replica, no machines: kubectl apply at 0 s"
for _ in $(seq 240); do [ "$(running)" = 1 ] && break; sleep 1; done
echo "    Running after $(el)"
show

echo "=== 2. three replicas that each need a machine of their own"
k patch deploy auto -p '{"spec":{"replicas":3,"template":{"spec":{"containers":[{"name":"web","resources":{"requests":{"cpu":"1","memory":"6Gi"}}}]}}}}' >/dev/null
t0=$(date +%s)
for _ in $(seq 300); do [ "$(running)" -ge 2 ] && [ "$(k get machines --no-headers 2>/dev/null | wc -l | tr -d ' ')" -ge 2 ] && break; sleep 2; done
sleep 20
echo "    two Running after $(el)"
show
pending=$(k get pods -l app=auto --field-selector=status.phase=Pending -o name | head -1)
if [ -n "$pending" ]; then
    echo "--- why $pending waits"
    k get events --field-selector "involvedObject.name=${pending#pod/}" -o custom-columns=REASON:.reason,MESSAGE:.message 2>&1 \
        | tail -4 | cut -c1-240 | sed 's/^/    /'
    grep -a "macOS guests at most\|waits for one to go" "/tmp/ferry-run-${state##*/.ferry-}/logs/ferry-karpenter.log" 2>/dev/null \
        | tail -2 | cut -c1-240 | sed 's/^/    karpenter: /'
fi

echo "=== 3. zero replicas: the machines go"
k scale deploy auto --replicas=0 >/dev/null
t0=$(date +%s)
for _ in $(seq 300); do [ "$(k get machines --no-headers 2>/dev/null | wc -l | tr -d ' ')" = 0 ] && break; sleep 2; done
echo "    no machines after $(el)"
show
k delete deploy auto >/dev/null 2>&1
