#!/usr/bin/env bash
# podStartSLOduration for every pod in a burst, from the kubelet's own tracker.
#
# This is the kubelet measuring itself: the interval it is responsible for,
# with scheduling and the API round trip already excluded. Both stacks run the
# same v1.37.0 kubelet and both emit the line, so it is the one number that
# compares the two runtimes directly.
#
#   burst.py      ferry 35.0 ms per concurrent pod, kind 11.3
#   ctrconc.sh    containerd does 20 containers in 165ms, 6x concurrency
#
# If podStartSLOduration is flat across the burst, the kubelet starts each pod
# quickly and something upstream is feeding them in slowly. If it climbs with
# position in the burst, pods are queueing inside the kubelet.
set -uo pipefail
cd "$(dirname "$0")"

STACK="${1:?usage: slodur.sh ferry|kind}"
case "$STACK" in
  ferry) kc="$(./ferry kubeconfig)"; node=perf-0
         sel='      nodeSelector: {ferry.dev/mode: shared}'
         logcmd='tail -n +MARK /host/var/log/kubelet.log' ;;
  kind)  kc="$HOME/.kube/config-perfk"
         node="$(KUBECONFIG=$kc kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
         sel=''
         # kind's kubelet runs under systemd and logs to the journal.
         logcmd='journalctl -u kubelet --no-pager -n 4000' ;;
esac
export KUBECONFIG="$kc"

kubectl delete pod slop --ignore-not-found >/dev/null 2>&1
kubectl create namespace slo >/dev/null 2>&1
kubectl -n slo delete deployment s --ignore-not-found >/dev/null 2>&1
sleep 3

cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: slop}
spec:
  nodeName: $node
  terminationGracePeriodSeconds: 0
  containers:
  - name: c
    image: alpine:3.20
    command: ["sleep","3600"]
    securityContext: {privileged: true, runAsUser: 0}
    volumeMounts: [{name: h, mountPath: /host}]
  volumes:
  - name: h
    hostPath: {path: /}
YAML
kubectl wait --for=condition=Ready pod/slop --timeout=180s >/dev/null 2>&1 || { echo "no probe"; exit 1; }

if [ "$STACK" = ferry ]; then
  mark=$(kubectl exec slop -- sh -c 'wc -l < /host/var/log/kubelet.log' 2>/dev/null | tr -d ' \r')
  logcmd="${logcmd/MARK/$mark}"
fi

cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata: {name: s, namespace: slo}
spec:
  replicas: 20
  selector: {matchLabels: {app: s}}
  template:
    metadata: {labels: {app: s}}
    spec:
      terminationGracePeriodSeconds: 0
$sel
      containers:
      - name: c
        image: alpine:3.20
        command: ["sleep","3600"]
YAML

for _ in $(seq 1 180); do
  r=$(kubectl -n slo get pods --no-headers 2>/dev/null | awk '$3=="Running"' | wc -l | tr -d ' ')
  [ "${r:-0}" -ge 20 ] && break
  sleep 1
done
sleep 3

if [ "$STACK" = ferry ]; then
  kubectl exec slop -- sh -c "$logcmd" 2>/dev/null > /tmp/slo-$STACK.log
else
  # No journalctl in the probe image; read the node's log through docker.
  docker exec "$node" sh -c "$logcmd" 2>/dev/null > /tmp/slo-$STACK.log
fi

echo "== $STACK: podStartSLOduration, 20-pod burst"
python3 - "/tmp/slo-$STACK.log" <<'PARSE'
import sys, re, statistics
vals = []
for line in open(sys.argv[1], errors="replace"):
    if "podStartSLOduration" not in line: continue
    m = re.search(r'podStartSLOduration=([0-9.]+)', line)
    p = re.search(r'pod="slo/([^"]+)"', line)
    if m and p: vals.append(float(m.group(1)) * 1000)
if not vals:
    print("  no samples in", sys.argv[1]); raise SystemExit(0)
vals.sort()
print(f"  n={len(vals)}  median={statistics.median(vals):7.1f}ms")
print(f"  min={vals[0]:7.1f}  p90={vals[int(len(vals)*.9)]:7.1f}  max={vals[-1]:7.1f}")
print(f"  sum={sum(vals):8.1f}ms  (if serialized, this is the wall time)")
PARSE

kubectl -n slo delete deployment s --wait=false >/dev/null 2>&1
kubectl delete pod slop --ignore-not-found --wait=false >/dev/null 2>&1
