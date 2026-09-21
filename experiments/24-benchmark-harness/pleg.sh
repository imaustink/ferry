#!/usr/bin/env bash
# Pod start with and without EventedPLEG, same node spec, same image.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FERRY="${FERRY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/ferry}"
SUBNET="$1"; shift
LABEL="$1"; shift    # "off" or "on"

"$FERRY" down --purge >/dev/null 2>&1; sleep 8
"$FERRY" up >/dev/null 2>&1
FERRY_MACHINE_SUBNET="$SUBNET" "$@" "$FERRY" machines enable >/dev/null 2>&1
kc=$("$FERRY" kubeconfig)
kubectl --kubeconfig "$kc" apply -f - >/dev/null 2>&1 <<YAML
apiVersion: ferry.dev/v1alpha1
kind: Machine
metadata: {name: worker-0}
spec: {cpus: 10, memory: 15Gi}
YAML
for _ in $(seq 1 300); do
  [ "$(kubectl --kubeconfig "$kc" get node worker-0 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] && break; sleep 1
done
export NODE_SELECTOR=$'      nodeSelector: {ferry.dev/mode: shared}\n'
bash "$here/curve.sh" ferry2 1 >/dev/null 2>&1   # warm the image cache
echo "=== EventedPLEG $LABEL ==="
for i in 1 2 3 4 5; do bash "$here/curve.sh" ferry2 1 2>&1 | grep "1 running" | sed 's/^/  single /'; done
bash "$here/curve.sh" ferry2 20 2>&1 | grep "20 running" | sed 's/^/  20 pods /'
# the kubelet's own number, and proof the gate is actually on
kubectl --kubeconfig "$kc" apply -f - >/dev/null 2>&1 <<'YAML'
apiVersion: v1
kind: Pod
metadata: {name: plegcheck, namespace: bench}
spec:
  hostNetwork: true
  nodeSelector: {ferry.dev/mode: shared}
  restartPolicy: Never
  volumes: [{name: v, hostPath: {path: /var/log}}, {name: k, hostPath: {path: /var/lib/kubelet}}]
  containers:
  - name: c
    image: alpine:3.20
    volumeMounts: [{name: v, mountPath: /hostlog}, {name: k, mountPath: /kubelet}]
    command: ["sh","-c","echo GATE:; grep -i featureGates /kubelet/config.yaml || echo '  (none)'; echo SLO:; grep -o 'podStartSLOduration=[0-9.]*' /hostlog/kubelet.log | cut -d= -f2 | sort -n | tail -20"]
YAML
for i in $(seq 1 90); do
  p=$(kubectl --kubeconfig "$kc" -n bench get pod plegcheck -o jsonpath='{.status.phase}' 2>/dev/null)
  { [ "$p" = Succeeded ] || [ "$p" = Failed ]; } && break; sleep 2
done
kubectl --kubeconfig "$kc" -n bench logs plegcheck 2>&1 | head -4
kubectl --kubeconfig "$kc" -n bench logs plegcheck 2>&1 | sed -n '/SLO:/,$p' | tail -n +2 | python3 -c "
import sys, statistics
v=[float(x) for x in sys.stdin if x.strip()]
print(f'  podStartSLOduration: n={len(v)} median {statistics.median(v):.3f}s min {min(v):.3f}s' if v else '  no SLO samples')"
