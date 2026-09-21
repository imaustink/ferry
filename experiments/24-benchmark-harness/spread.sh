#!/usr/bin/env bash
# Do 20 pods start together or one after another?
#
# 5.64s for 20 pods on mode 2 against 1.23s on kind is either 20 slow parallel
# starts or a serialized queue. The per-pod Ready transition says which.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/stacks.sh"
STACK="$1"; N="${2:-20}"
kc=$(kubeconfig_of "$STACK"); ctx=$(context_of "$STACK")
K() { if [ -n "$ctx" ]; then kubectl --kubeconfig "$kc" --context "$ctx" "$@"; else kubectl --kubeconfig "$kc" "$@"; fi; }

K create ns bench >/dev/null 2>&1
K -n bench delete deployment bench --wait=true >/dev/null 2>&1; sleep 5

K apply -f - >/dev/null <<YAML
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
${NODE_SELECTOR:-}      containers:
      - name: c
        image: alpine:3.20
        command: ["sleep","3600"]
YAML

for _ in $(seq 1 600); do
  r=$(K -n bench get pods --no-headers 2>/dev/null | awk '$3=="Running"' | wc -l | tr -d ' ')
  [ "${r:-0}" -ge "$N" ] && break; sleep 0.2
done

echo "=== $STACK: when each pod became Ready ==="
K -n bench get pods -o json 2>/dev/null | python3 "$BENCH_HOME/spread.py"
echo "=== image pull events (none expected -- image is cached) ==="
K -n bench get events --field-selector reason=Pulling 2>/dev/null | head -4
K -n bench delete deployment bench --wait=true >/dev/null 2>&1
