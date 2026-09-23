#!/bin/bash
# SCTP pod-to-pod and through a ClusterIP, same node or across two.
#
#   sctp.sh <server-node> <client-node>
#
# Needs KUBECONFIG pointing at a running ferry cluster.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
server_node="$1" client_node="${2:-$1}"

kubectl delete pod sctp-server sctp-client --ignore-not-found --wait=true >/dev/null
sed -e "s/SERVER_NODE/$server_node/" -e "s/CLIENT_NODE/$client_node/" "$here/sctp.yaml" |
  kubectl apply -f - >/dev/null
kubectl wait --for=condition=Ready pod/sctp-server pod/sctp-client --timeout=240s >/dev/null

server_ip="$(kubectl get pod sctp-server -o jsonpath='{.status.podIP}')"
client_ip="$(kubectl get pod sctp-client -o jsonpath='{.status.podIP}')"
cluster_ip="$(kubectl get svc sctp-echo -o jsonpath='{.spec.clusterIP}')"
echo "server $server_ip on $server_node, client $client_ip on $client_node, ClusterIP $cluster_ip"

run() { printf '%-28s ' "$1"; shift; kubectl exec sctp-client -- python3 /scripts/client.py "$@" 2>&1 | tail -1; }
for i in 1 2 3; do
  run "pod IP ($i)" "$server_ip" 9999
done
for i in 1 2 3; do
  run "ClusterIP ($i)" "$cluster_ip" 7777
done
run "by name" sctp-echo.default.svc.cluster.local 7777
run "ClusterIP, wrong port" "$cluster_ip" 7778
echo "server kernel's SCTP counters:"
kubectl exec sctp-server -- sh -c 'grep -E "SctpCurrEstab|SctpActiveEstabs|SctpPassiveEstabs" /proc/net/sctp/snmp'
