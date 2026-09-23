#!/usr/bin/env bash
# Policy on a joined node, then how long it takes to get there.
# usage: run.sh <joined-node> <server-node> <hostport> [trials]
# with KUBECONFIG pointing at the cluster.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
KEEP=1 "$here/../34-join-policy/policy.sh" "$1" "$2" "$3" || exit 1
kubectl wait --for=condition=Ready pod/e34web pod/e34cli --timeout=60s >/dev/null
ip="$(kubectl get pod e34web -o jsonpath='{.status.podIP}')"
python3 "$here/latency.py" e34cli "$ip" "$3" "${4:-7}"
kubectl delete pod e34web e34cli --wait=false >/dev/null
