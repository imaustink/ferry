#!/usr/bin/env bash
# Apply the Deployment/Service/NetworkPolicy/PodDisruptionBudget, wait for
# the rollout, then prove the Service actually answers -- from inside the
# cluster, by DNS name, the way every other pod reaches it. Exits non-zero
# on any failure, so CI can gate on it.
#
#   ./run.sh
set -euo pipefail
cd "$(dirname "$0")"

: "${KUBECONFIG:=$HOME/.ferry/admin.conf}"
export KUBECONFIG

echo "==> applying manifests"
kubectl apply -k manifests/

echo "==> waiting for the rollout"
kubectl rollout status deployment/node-app --timeout=120s

echo "==> pods"
kubectl get pods -l app=node-app -o wide

# Services route inside pods on ferry, in each pod's own kernel -- kube-proxy
# cannot run on the Mac's kernel, which has no netfilter (docs/SERVICES.md).
# So the Service is proven from inside the cluster, by its DNS name, the way
# every other pod actually reaches it -- not by curling the ClusterIP from
# the Mac, which has nothing to route it.
pod=$(kubectl get pods -l app=node-app -o jsonpath='{.items[0].metadata.name}')
echo
echo "==> node-app Service, reached by DNS name from inside pod $pod"
kubectl exec "$pod" -- node -e \
  "require('http').get('http://node-app/',r=>{let b='';r.on('data',d=>b+=d);r.on('end',()=>{process.stdout.write(b);process.exit(r.statusCode===200?0:1)})})"

echo
echo "==> readiness of that same pod, direct"
kubectl exec "$pod" -- node -e \
  "require('http').get('http://127.0.0.1:8080/readyz',r=>{console.log(r.statusCode);process.exit(r.statusCode===200?0:1)})"

echo
echo "==> logs ($pod)"
kubectl logs "$pod"
