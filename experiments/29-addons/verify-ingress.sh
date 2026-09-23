#!/bin/bash
k="${K:-kubectl}"   # KUBECONFIG set to the cluster under test
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
  ingressClassName: nginx
  rules:
  - host: web.ferry.test
    http:
      paths:
      - {path: /, pathType: Prefix, backend: {service: {name: echo, port: {number: 80}}}}
EOF
$k rollout status deploy/echo --timeout=120s
np="$($k -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')"
for i in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: web.ferry.test' "http://127.0.0.1:$np/hostname")"
  [ "$code" = 200 ] && break; sleep 1
done
echo "Ingress via node port $np: $code $(curl -s -H 'Host: web.ferry.test' "http://127.0.0.1:$np/hostname")"
$k delete ingress echo; $k delete svc echo; $k delete deploy echo
