#!/bin/bash
k="${K:-kubectl}"   # KUBECONFIG set to the cluster under test
echo "invalid issuer (webhook must deny):"
printf 'apiVersion: cert-manager.io/v1\nkind: Issuer\nmetadata: {name: bad, namespace: default}\nspec: {}\n' | $k apply -f - 2>&1 | sed 's/^/  /'
start=$(date +%s)
$k apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: {name: selfsigned}
spec: {selfSigned: {}}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: example, namespace: default}
spec:
  secretName: example-tls
  dnsNames: [example.ferry.test]
  issuerRef: {name: selfsigned, kind: ClusterIssuer}
EOF
$k wait --for=condition=Ready certificate/example --timeout=120s
echo "issued in $(( $(date +%s) - start ))s"
$k get secret example-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -ext subjectAltName -enddate
$k delete certificate example; $k delete secret example-tls; $k delete clusterissuer selfsigned
