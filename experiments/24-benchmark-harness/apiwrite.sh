#!/usr/bin/env bash
# What one API write costs from inside a node, and therefore what twenty cost.
#
# After the volume manager's poll intervals and both fsync barriers, the
# largest thing left in a ferry burst is not in the kubelet: the kubelet has
# all twenty pods Running within 55ms and their statuses are not all stored
# for another 584ms. The status manager writes them one at a time, so the
# per-write cost is multiplied by the size of the burst.
#
# This measures that write on the path the kubelet uses -- from a pod on the
# node, on the node's own network -- rather than from the Mac, where the
# answer would be a different number about a different route.
#
# For ferry it also measures each address the guest *could* be told the API
# server is on. The guest is currently given the Mac's LAN address, so its
# packets leave vmnet and come back through the host's LAN interface; the
# vmnet gateway is the host end of the interface the guest is already on.
#
# Usage: apiwrite.sh ferry|kind [writes]
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/stacks.sh"

STACK="${1:-ferry}"
N="${2:-50}"
NS=apiwrite
POD=apiwrite
IMAGE="${APIWRITE_IMAGE:-python:3.12-alpine}"

case "$STACK" in
  ferry|ferry2)
    kc="$(kubeconfig_of ferry2)"; ctx=""
    node="$(KUBECONFIG=$kc kubectl get nodes -l ferry.dev/mode=shared \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
    [ -n "$node" ] || { echo "  no ferry.dev/mode=shared node; is mode 2 on?"; exit 1; }
    port="$(KUBECONFIG=$kc kubectl config view --minify \
      -o jsonpath='{.clusters[0].cluster.server}' | sed 's|.*:||')" ;;
  kind)
    kc="$(kubeconfig_of kind)"; ctx="$(context_of kind)"
    node="$(KUBECONFIG=$kc kubectl --context "$ctx" get nodes \
      -o jsonpath='{.items[0].metadata.name}')"
    port=6443 ;;
  *) echo "usage: apiwrite.sh ferry|kind [writes]" >&2; exit 2 ;;
esac
k() { if [ -n "$ctx" ]; then KUBECONFIG="$kc" kubectl --context "$ctx" "$@";
      else KUBECONFIG="$kc" kubectl "$@"; fi; }

echo "== $STACK, node $node, $N sequential writes"

# A namespace of its own with an account allowed to patch one configmap. The
# default account cannot write anything, and granting it more than this to
# run a benchmark would outlive the benchmark.
k delete ns "$NS" --ignore-not-found --wait=true >/dev/null 2>&1
k create ns "$NS" >/dev/null
k -n "$NS" create configmap apiwrite --from-literal=n=0 >/dev/null
cat <<YAML | k apply -f - >/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: apiwrite, namespace: $NS}
rules:
- apiGroups: [""]
  resources: [configmaps]
  verbs: [get, patch, update]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: apiwrite, namespace: $NS}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: apiwrite}
subjects:
- {kind: ServiceAccount, name: default, namespace: $NS}
YAML

# hostNetwork, so the probe is on the node's network rather than the pod
# network -- the kubelet is not behind CNI and neither should this be.
cat <<YAML | k apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: $POD, namespace: $NS}
spec:
  nodeName: $node
  hostNetwork: true
  terminationGracePeriodSeconds: 0
  containers:
  - name: c
    image: $IMAGE
    command: ["sleep","3600"]
YAML
k -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=300s >/dev/null 2>&1 \
  || { echo "  probe pod never became Ready (image pull?)"; exit 1; }

k -n "$NS" cp "$BENCH_HOME/apiwrite.py" "$POD:/tmp/apiwrite.py" >/dev/null 2>&1

# Which addresses to try. For ferry: what the guest was actually told, and
# the gateway of the network it is already on, read off the guest rather than
# assumed -- the machine subnet moves every time the cluster is recreated.
targets=()
if [ "$STACK" = kind ]; then
  targets+=("https://127.0.0.1:$port")
else
  told="$(k -n "$NS" exec "$POD" -- sh -c \
    'tr " " "\n" < /proc/cmdline | sed -n "s|^ferry.api=https://||p"' 2>/dev/null | tr -d '\r')"
  [ -n "$told" ] && targets+=("https://$told")
  gw="$(k -n "$NS" exec "$POD" -- sh -c \
    "ip route | sed -n 's/^default via \([0-9.]*\).*/\1/p'" 2>/dev/null | tr -d '\r')"
  [ -n "$gw" ] && targets+=("https://$gw:$port")
fi

for t in ${targets[@]+"${targets[@]}"}; do
  k -n "$NS" exec "$POD" -- python3 /tmp/apiwrite.py "$t" "$N" 2>&1 | sed 's/^/  /'
done

k delete ns "$NS" --ignore-not-found --wait=false >/dev/null 2>&1
