#!/bin/bash
# Port-forward the dashboard and use its own API with the admin token.
k="${K:-kubectl}"   # KUBECONFIG set to the cluster under test
token="$(cat "${FERRY_HOME:-$HOME/.ferry}/addons/dashboard/token")"
$k -n kubernetes-dashboard port-forward svc/kubernetes-dashboard 28443:443 >/dev/null 2>&1 &
pf=$!
trap 'kill $pf' EXIT
for i in $(seq 1 30); do curl -sk -o /dev/null https://localhost:28443/ && break; sleep 0.5; done
echo "index: $(curl -sk -o /dev/null -w '%{http_code}' https://localhost:28443/)"
echo "login modes: $(curl -sk https://localhost:28443/api/v1/login/modes)"
echo "pods in kube-system seen through the dashboard with the token:"
curl -sk -H "Authorization: Bearer $token" https://localhost:28443/api/v1/pod/kube-system | jq -r '.pods[].objectMeta.name'
echo "without a token: $(curl -sk -o /dev/null -w '%{http_code}' https://localhost:28443/api/v1/pod/kube-system)"
echo "node metrics via scraper: $(curl -sk -H "Authorization: Bearer $token" https://localhost:28443/api/v1/node | jq -c '.cumulativeMetrics | length')"
