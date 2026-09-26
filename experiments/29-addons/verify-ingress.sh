#!/bin/bash
# verify-ingress.sh [nginx|traefik]: an Ingress with a host rule answering
# through the controller's node port, and through its LoadBalancer on the Mac's
# own 80 and 443 at localhost and the LAN address. The Ingress names no class,
# so it is served only if the controller's class is the default.
k="${K:-kubectl}"   # KUBECONFIG set to the cluster under test
case "${1:-nginx}" in
  nginx)   svc=ingress-nginx/ingress-nginx-controller ;;
  traefik) svc=traefik/traefik ;;
  *) echo "usage: $0 [nginx|traefik]" >&2; exit 2 ;;
esac
ns="${svc%/*}"; svc="${svc#*/}"

$k apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: echo, namespace: default}
spec:
  replicas: 1
  selector: {matchLabels: {app: echo}}
  template:
    metadata: {labels: {app: echo}}
    spec:
      containers:
      - {name: echo, image: "registry.k8s.io/e2e-test-images/agnhost:2.53", args: ["netexec", "--http-port=8080"]}
---
apiVersion: v1
kind: Service
metadata: {name: echo, namespace: default}
spec:
  selector: {app: echo}
  ports: [{port: 80, targetPort: 8080}]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: {name: echo, namespace: default}
spec:
  rules:
  - host: web.ferry.test
    http:
      paths:
      - {path: /, pathType: Prefix, backend: {service: {name: echo, port: {number: 80}}}}
EOF
$k rollout status deploy/echo --timeout=120s
echo "class given by default: $($k get ingress echo -o jsonpath='{.spec.ingressClassName}')"

try() { # label url [curl args]; HOST overrides the host asked for
  local label="$1" url="$2" code; shift 2
  for _ in $(seq 1 60); do
    code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${HOST:-web.ferry.test}" "$@" "$url/hostname")"
    [ "$code" = 200 ] || [ -n "${HOST:-}" ] && break; sleep 1
  done
  echo "$label: $code"
}
np="$($k -n "$ns" get svc "$svc" -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')"
try "node port $np" "http://127.0.0.1:$np"
# The address ferry-proxy published, rather than a guess at which interface is
# the LAN: en0 is not it on every Mac. Empty when this Service did not get the
# Mac's 80 and 443 -- and then whatever answers there is somebody else.
lan="$($k -n "$ns" get svc "$svc" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
if [ -n "$lan" ]; then
  try "localhost:80" "http://localhost"
  try "$lan:80" "http://$lan"
  try "localhost:443" "https://localhost" -k
  HOST=nobody.ferry.test try "another host" "http://localhost"
else
  echo "Mac's 80 and 443: not this Service's; kubectl -n $ns describe svc $svc says why"
fi
echo "Service: $($k -n "$ns" get svc "$svc" --no-headers)"
$k delete ingress echo; $k delete svc echo; $k delete deploy echo
