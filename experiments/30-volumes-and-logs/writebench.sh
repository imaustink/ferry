#!/usr/bin/env bash
# Runs writebench.yaml N times and prints the timings.
set -euo pipefail
cd "$(dirname "$0")"
for i in $(seq 1 "${1:-3}"); do
  kubectl delete pod writebench --ignore-not-found --wait >/dev/null
  kubectl apply -f writebench.yaml >/dev/null
  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/writebench --timeout=180s >/dev/null
  kubectl logs writebench | grep -E "^/|real"
done
kubectl delete pod writebench --wait >/dev/null
