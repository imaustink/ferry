#!/usr/bin/env bash
# `kubectl logs --previous` against a crashlooping container, polled every
# 0.2s for DURATION seconds once the first restart has happened. Counts the
# answers that were not the previous attempt's log.
#   ./previous.sh [DURATION]
set -euo pipefail
DURATION=${1:-180}
kubectl delete pod crasher --ignore-not-found --wait >/dev/null
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Pod
metadata: {name: crasher}
spec:
  terminationGracePeriodSeconds: 0
  containers:
  - name: c
    image: alpine:3.20
    command: [sh, -c, 'echo "attempt at $(date +%s)"; sleep 2; exit 1']
YAML
until [ "$(kubectl get pod crasher -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)" -ge 1 ] 2>/dev/null; do sleep 0.5; done
ok=0 fail=0
end=$(( $(date +%s) + DURATION ))
while [ "$(date +%s)" -lt "$end" ]; do
  if out=$(kubectl logs crasher --previous 2>&1) && [[ $out == attempt* ]]; then
    ok=$((ok + 1))
  else
    fail=$((fail + 1))
    echo "$(date +%T) $out" | head -1
  fi
  sleep 0.2
done
echo "restarts=$(kubectl get pod crasher -o jsonpath='{.status.containerStatuses[0].restartCount}') ok=$ok fail=$fail"
kubectl delete pod crasher --wait >/dev/null
