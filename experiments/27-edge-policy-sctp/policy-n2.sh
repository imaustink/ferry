#!/bin/bash
# deny-all against a pod on the second node: its own node still probes it, a pod
# on the first node and the edge do not get in.
#
#   policy-n2.sh <lan-ip> <node-port of web2>
set -u
lan="$1" nodeport="$2"
web2="$(kubectl get pod web2 -o jsonpath='{.status.podIP}')"
state() { kubectl get pod web2 -o jsonpath='ready={.status.containerStatuses[0].ready} restarts={.status.containerStatuses[0].restartCount}'; }
run() {
  printf '  %-36s %s\n' "LAN -> node port $lan:$nodeport" \
    "$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://$lan:$nodeport/" | sed 's/^200$/200 served/;s/^000$/refused/')"
  printf '  %-36s %s\n' "pod on node 0 -> $web2:80" \
    "$(kubectl exec sctp-client -- wget -q -T 3 -O /dev/null "http://$web2/" >/dev/null 2>&1 && echo '200 served' || echo refused)"
  printf '  %-36s %s\n' "web2" "$(state)"
}
kubectl delete networkpolicy --all >/dev/null
echo "no policy"; sleep 3; run
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: deny-all}
spec: {podSelector: {}, policyTypes: [Ingress]}
EOF
echo "deny-all"; sleep 4; run
sleep 30; printf '  %-36s %s\n' "web2, 30s later" "$(state)"
kubectl delete networkpolicy --all >/dev/null
