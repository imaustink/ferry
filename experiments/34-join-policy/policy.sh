#!/usr/bin/env bash
# Does a joined node enforce NetworkPolicy in its pods and at its edge?
# usage: e34-joinpol.sh <joined-node> <server-node> <hostport>
set -u
K=kubectl   # with KUBECONFIG pointing at the cluster
joined="$1" server="$2" hp="$3"
$K delete pod e34web e34cli --ignore-not-found --wait=true >/dev/null 2>&1
$K delete networkpolicy e34-friends-only --ignore-not-found >/dev/null 2>&1
$K apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: {name: e34web, labels: {app: e34web}}
spec:
  nodeName: $joined
  containers:
  - name: web
    image: docker.io/library/busybox:1.36
    command: ["sh", "-c", "echo hello > /tmp/index.html && httpd -f -h /tmp -p 80"]
    ports: [{containerPort: 80, hostPort: $hp}]
---
apiVersion: v1
kind: Pod
metadata: {name: e34cli}
spec:
  nodeName: $server
  containers:
  - name: c
    image: docker.io/library/busybox:1.36
    command: ["sleep", "3600"]
YAML
$K wait --for=condition=Ready pod/e34web pod/e34cli --timeout=180s >/dev/null || { $K get pods -o wide; exit 1; }
ip="$($K get pod e34web -o jsonpath='{.status.podIP}')"
echo "web $ip on $joined, client on $server"
probe() {
  local pod edge
  pod="$($K exec e34cli -- wget -q -T 3 -O - "http://$ip/" 2>/dev/null || echo BLOCKED)"
  edge="$(curl -s --max-time 3 "http://127.0.0.1:$hp/" || echo BLOCKED)"
  echo "  $1: pod->pod $pod | edge 127.0.0.1:$hp $edge"
}
sleep 3
probe "no policy     "
$K apply -f - >/dev/null <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: e34-friends-only}
spec:
  podSelector: {matchLabels: {app: e34web}}
  policyTypes: [Ingress]
  ingress:
  - from: [{podSelector: {matchLabels: {role: friend}}}]
YAML
sleep 5
probe "friends only  "
$K label pod e34cli role=friend >/dev/null
sleep 5
probe "client=friend "
$K delete networkpolicy e34-friends-only >/dev/null
$K delete pod e34web e34cli --wait=false >/dev/null
