#!/bin/bash
k="${K:-kubectl}"   # KUBECONFIG set to the cluster under test
d="$(cd "$(dirname "$0")" && pwd)"
start=$(date +%s)
$k apply -f $d/gw-test.yaml
$k wait --for=condition=Programmed gateway/web --timeout=180s
$k rollout status deploy/echo --timeout=120s
echo "gateway programmed after $(( $(date +%s) - start ))s"
$k get gateway web
$k -n envoy-gateway-system get svc,pods
addr="$($k get gateway web -o jsonpath='{.status.addresses[0].value}')"
echo "gateway address: $addr"
for i in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: echo.ferry.test' "http://$addr:8088/hostname")"
  [ "$code" = 200 ] && break; sleep 1
done
echo "GET /hostname via Host echo.ferry.test: $code $(curl -s -H 'Host: echo.ferry.test' "http://$addr:8088/hostname")"
echo "wrong host: $(curl -s -o /dev/null -w '%{http_code}' -H 'Host: other.test' "http://$addr:8088/")"
echo "route: $($k get httproute echo -o jsonpath='{.status.parents[0].conditions[*].type}={.status.parents[0].conditions[*].status}')"
