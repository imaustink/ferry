#!/usr/bin/env bash
# kubectl port-forward to a macOS pod, with both ends' logs shown.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
state=$("$here/../../ferry" profile | awk '$1 == "state" {print $2}')
export KUBECONFIG="$state/admin.conf"
kubectl delete pod pf --ignore-not-found >/dev/null 2>&1
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: pf, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-macos-shared
  containers: [{name: web, image: "example.com/podsrv-darwin:3", args: [serve, pf]}]
EOF
kubectl wait --for=condition=Ready pod/pf --timeout=60s >/dev/null
kubectl port-forward pod/pf 18081:8080 > "$here/build/pf.log" 2>&1 &
pf=$!
for _ in $(seq 50); do grep -q Forwarding "$here/build/pf.log" && break; sleep 0.1; done
echo "--- through the forward"
"$here/build/netpod/bin/podsrv" get 127.0.0.1 18081 2>&1 | sed 's/^/    /'
sleep 1
kill $pf 2>/dev/null
echo "--- kubectl port-forward said"
sed 's/^/    /' "$here/build/pf.log"
echo "--- ferry-darwin said"
grep -a "port-forward\|streaming" "$state/machined/mac-0.macvm.logs/runtime.log" | tail -4 | sed 's/^/    /'
kubectl delete pod pf --wait=false >/dev/null 2>&1
