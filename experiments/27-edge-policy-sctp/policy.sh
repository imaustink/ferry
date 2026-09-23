#!/bin/bash
# NetworkPolicy against clients from outside the cluster.
#
#   policy.sh <lan-ip> <node-port>
#
# Needs edge.yaml applied (pod "web", LoadBalancer on 80 with a node port, and
# probes on a port of their own) and a pod "sctp-client" to act as an in-cluster
# peer. Each case applies one policy, waits for it to reach the pod and the edge,
# and tries every way in.
set -u
lan="$1" nodeport="$2"
web="$(kubectl get pod web -o jsonpath='{.status.podIP}')"
gateway="${web%.*}.1"

try() { # label url
  local code
  code="$(curl -s -m 3 -o /dev/null -w '%{http_code}' "$2" 2>/dev/null)"
  [ "$code" = 200 ] && code="200 served" || code="refused"
  printf '  %-34s %s\n' "$1" "$code"
}
from_pod() { # label url
  local out
  out="$(kubectl exec sctp-client -- wget -q -T 3 -O /dev/null "$2" 2>&1 && echo "200 served" || echo refused)"
  printf '  %-34s %s\n' "$1" "${out##*$'\n'}"
}
all() {
  try "LAN        $lan:80" "http://$lan/"
  try "localhost  127.0.0.1:80" "http://127.0.0.1/"
  try "node port  $lan:$nodeport" "http://$lan:$nodeport/"
  try "Mac -> pod $web:80 (node)" "http://$web/"
  from_pod "pod -> pod $web:80" "http://$web/"
  from_pod "pod -> node port $gateway:$nodeport" "http://$gateway:$nodeport/"
  printf '  %-34s %s\n' "web" "$(kubectl get pod web -o jsonpath='ready={.status.containerStatuses[0].ready} restarts={.status.containerStatuses[0].restartCount}')"
}
policy() { # name, then the spec on stdin
  kubectl delete networkpolicy --all >/dev/null
  if [ "$1" != none ]; then
    { printf 'apiVersion: networking.k8s.io/v1\nkind: NetworkPolicy\nmetadata: {name: %s}\nspec:\n' "$1"; cat; } |
      kubectl apply -f - >/dev/null
  fi
  sleep 4 # a policy reaches a pod in a couple of seconds
  echo "$1"
}

policy none </dev/null; all

policy deny-all <<'EOF'
  podSelector: {}
  policyTypes: [Ingress]
EOF
all
echo "  (after 20s more, probes still passing?)"; sleep 20
printf '  %-34s %s\n' "web" "$(kubectl get pod web -o jsonpath='ready={.status.containerStatuses[0].ready} restarts={.status.containerStatuses[0].restartCount}')"

policy allow-the-lan-address <<EOF
  podSelector: {matchLabels: {app: web}}
  ingress:
    - from: [{ipBlock: {cidr: $lan/32}}]
      ports: [{port: 80}]
EOF
all

policy everyone-except-the-lan-address <<EOF
  podSelector: {matchLabels: {app: web}}
  ingress:
    - from: [{ipBlock: {cidr: 0.0.0.0/0, except: [$lan/32]}}]
EOF
all

policy only-the-client-pod <<'EOF'
  podSelector: {matchLabels: {app: web}}
  ingress:
    - from: [{podSelector: {matchLabels: {app: sctp-client}}}]
EOF
all

policy wrong-port <<'EOF'
  podSelector: {matchLabels: {app: web}}
  ingress:
    - ports: [{port: 81}]
EOF
all

policy none </dev/null; all
