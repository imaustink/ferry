#!/usr/bin/env bash
# Starts one pod of N busybox containers and reports how long it took to be
# Ready, then deletes it.
#   fanout.sh <containers> [image]
set -euo pipefail
n=${1:-8}
image=${2:-busybox:1.36}
name="fan$n"
{
  echo "apiVersion: v1"
  echo "kind: Pod"
  echo "metadata: {name: $name}"
  echo "spec:"
  echo "  terminationGracePeriodSeconds: 1"
  echo "  containers:"
  for i in $(seq 1 "$n"); do
    echo "  - {name: c$i, image: \"$image\", command: [sleep, \"36000\"]}"
  done
} > "/tmp/ferry-e31-$name.yaml"
start=$(python3 -c 'import time; print(time.time())')
kubectl apply -f "/tmp/ferry-e31-$name.yaml" >/dev/null
if kubectl wait --for=condition=Ready "pod/$name" --timeout=120s >/dev/null 2>&1; then
  python3 -c "import time; print('$name ready in %.2fs' % (time.time() - $start))"
else
  echo "$name not ready after 120s: $(kubectl get pod "$name" --no-headers)"
  kubectl describe pod "$name" | grep -iE "error|failed" | tail -3
fi
kubectl delete pod "$name" --wait=true >/dev/null
