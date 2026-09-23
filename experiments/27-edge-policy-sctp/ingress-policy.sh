#!/bin/bash
# deny-all in the ingress-nginx namespace: the controller keeps passing its
# probes and its admission webhook keeps answering the API server (both come
# from the node), while the LoadBalancer refuses; then an ipBlock lets the LAN
# address back in on 80.
#
#   ingress-policy.sh <lan-ip>
set -u
lan="$1"
show() {
  printf '  %-30s %s\n' "LAN :80" "$(curl -s -m 3 -o /dev/null -w '%{http_code}' -H 'Host: web.ferry.test' "http://$lan/" | sed 's/^000$/refused/')"
  printf '  %-30s %s\n' "localhost :80" "$(curl -s -m 3 -o /dev/null -w '%{http_code}' -H 'Host: web.ferry.test' http://localhost/ | sed 's/^000$/refused/')"
  printf '  %-30s %s\n' "admission webhook (new Ingress)" "$(sed "s/name: web2$/name: webhook-check/" "$(dirname "$0")/ingress.yaml" | kubectl create --dry-run=server -f - 2>&1 | tail -1)"
  printf '  %-30s %s\n' "controller" "$(kubectl -n ingress-nginx get pod -l app.kubernetes.io/component=controller -o jsonpath='ready={.items[0].status.containerStatuses[0].ready} restarts={.items[0].status.containerStatuses[0].restartCount}')"
}
kubectl -n ingress-nginx delete networkpolicy --all >/dev/null
echo "no policy"; show
kubectl -n ingress-nginx apply -f - >/dev/null <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: deny-all}
spec: {podSelector: {}, policyTypes: [Ingress]}
EOF
sleep 4; echo "deny-all"; show
sleep 30; echo "deny-all, 30s later"; show
kubectl -n ingress-nginx apply -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: lan-on-80}
spec:
  podSelector: {matchLabels: {app.kubernetes.io/component: controller}}
  ingress: [{from: [{ipBlock: {cidr: $lan/32}}], ports: [{port: http}]}]
EOF
sleep 4; echo "deny-all + ipBlock $lan/32 on the named port http"; show
kubectl -n ingress-nginx delete networkpolicy --all >/dev/null
