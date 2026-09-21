#!/usr/bin/env bash
# Separate "the control plane created 20 Pod objects" from "the node started
# them". If the floor is in creation, the runtime is innocent.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/stacks.sh"
STACK="$1"; N="${2:-20}"; MODE="${3:-deployment}"
kc=$(kubeconfig_of "$STACK"); ctx=$(context_of "$STACK")
K() { if [ -n "$ctx" ]; then kubectl --kubeconfig "$kc" --context "$ctx" "$@"; else kubectl --kubeconfig "$kc" "$@"; fi; }
K create ns bench >/dev/null 2>&1
K -n bench delete deployment bench --wait=true >/dev/null 2>&1
K -n bench delete pod --all --wait=true >/dev/null 2>&1; sleep 6

f="$BENCH_HOME/.obj.yaml"; : > "$f"
if [ "$MODE" = deployment ]; then
  cat > "$f" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: bench, namespace: bench}
spec:
  replicas: $N
  selector: {matchLabels: {app: bench}}
  template:
    metadata: {labels: {app: bench}}
    spec:
      terminationGracePeriodSeconds: 0
${NODE_SELECTOR:-}      containers: [{name: c, image: "alpine:3.20", command: ["sleep","3600"]}]
YAML
else
  for i in $(seq 1 "$N"); do
    cat >> "$f" <<YAML
---
apiVersion: v1
kind: Pod
metadata: {name: bare-$i, namespace: bench, labels: {app: bench}}
spec:
  terminationGracePeriodSeconds: 0
${NODE_SELECTOR:-}  containers: [{name: c, image: "alpine:3.20", command: ["sleep","3600"]}]
YAML
  done
fi

t0=$(python3 -c 'import time;print(time.time())')
K apply -f "$f" >/dev/null 2>&1
objs=-1; runs=-1
while :; do
  line=$(K -n bench get pods -o "custom-columns=P:.metadata.name,N:.spec.nodeName,S:.status.phase" --no-headers 2>/dev/null)
  o=$(printf '%s\n' "$line" | grep -c .)
  b=$(printf '%s\n' "$line" | awk '$2!="<none>" && $2!=""' | grep -c .)
  r=$(printf '%s\n' "$line" | awk '$3=="Running"' | grep -c .)
  if [ "$o" != "$objs" ] || [ "$r" != "$runs" ] || [ "$b" != "${bnd:-}" ]; then
    python3 -c "import time;print(f'  {time.time()-$t0:6.2f}s   objects {$o:>3}   bound {$b:>3}   running {$r:>3}')"
    objs=$o; runs=$r; bnd=$b
  fi
  [ "$r" -ge "$N" ] && break
  [ "$(python3 -c "import time;print(int(time.time()-$t0))")" -gt 90 ] && { echo "  timeout"; break; }
done
K -n bench delete deployment bench --wait=true >/dev/null 2>&1
K -n bench delete pod --all --wait=true >/dev/null 2>&1
