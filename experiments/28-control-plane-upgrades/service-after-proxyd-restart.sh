#!/usr/bin/env bash
# How long after ferry-proxyd restarts a brand-new Service reaches the pods.
#
# ferry-cri long-polls ferry-proxyd for the ruleset "after" the generation it
# has. Run right after 'ferry upgrade node' has restarted ferry-proxyd: it
# creates a Service in front of the web pods from workload.yaml and times how
# long until the client pod can reach it by ClusterIP.
#
#   KUBECONFIG=... ./service-after-proxyd-restart.sh
set -uo pipefail
kubectl delete service after-restart --ignore-not-found >/dev/null 2>&1
kubectl create service clusterip after-restart --tcp=80:80 >/dev/null
kubectl patch service after-restart -p '{"spec":{"selector":{"app":"web"}}}' >/dev/null
ip="$(kubectl get service after-restart -o jsonpath='{.spec.clusterIP}')"
start=$(python3 -c 'import time;print(time.time())')
for i in $(seq 1 60); do
  if kubectl exec deploy/client -- wget -q -O /dev/null -T 1 "http://$ip/" >/dev/null 2>&1; then
    echo "Service $ip reachable $(python3 -c "import time;print(round(time.time()-$start,1))")s after it was created"
    kubectl delete service after-restart >/dev/null 2>&1
    exit 0
  fi
  sleep 0.5
done
echo "Service $ip still unreachable after 60 tries"
exit 1
