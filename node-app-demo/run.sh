#!/usr/bin/env bash
# Apply the pod, wait for it to be Running, then curl it over the pod
# network (the Mac is on that subnet already -- no port-forward needed).
#
#   ./run.sh
set -euo pipefail
cd "$(dirname "$0")"

: "${KUBECONFIG:=$HOME/.ferry/admin.conf}"
export KUBECONFIG

echo "==> applying manifests"
kubectl delete pod node-app-demo --ignore-not-found --wait=true >/dev/null
kubectl apply -f manifests/pod.yaml

echo "==> waiting for node-app-demo"
for _ in $(seq 300); do
    phase=$(kubectl get pod node-app-demo -o jsonpath='{.status.phase}' 2>/dev/null || true)
    [ "$phase" = "Running" ] && break
    sleep 0.5
done

echo "==> pod status"
kubectl get pod node-app-demo -o wide

ip=$(kubectl get pod node-app-demo -o jsonpath='{.status.podIP}')
echo
echo "==> curl http://$ip:8080/"
curl -fsS "http://$ip:8080/" || true

echo
echo "==> logs"
kubectl logs node-app-demo
