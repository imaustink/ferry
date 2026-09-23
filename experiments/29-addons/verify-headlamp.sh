#!/bin/bash
k="${K:-kubectl}"   # KUBECONFIG set to the cluster under test
token="$(cat "${FERRY_HOME:-$HOME/.ferry}/addons/headlamp/token")"
$k -n kube-system port-forward svc/headlamp 24466:80 >/dev/null 2>&1 &
pf=$!
trap 'kill $pf' EXIT
for i in $(seq 1 30); do curl -s -o /dev/null http://localhost:24466/ && break; sleep 0.5; done
echo "index: $(curl -s -o /dev/null -w '%{http_code}' http://localhost:24466/)"
echo "config: $(curl -s http://localhost:24466/config | jq -c '[.clusters[].name]')"
echo "namespaces through headlamp with the token:"
curl -s -H "Authorization: Bearer $token" http://localhost:24466/clusters/main/api/v1/namespaces | jq -r '.items[].metadata.name' | tr '\n' ' '; echo
echo "without a token: $(curl -s -o /dev/null -w '%{http_code}' http://localhost:24466/clusters/main/api/v1/namespaces)"
