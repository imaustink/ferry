#!/usr/bin/env bash
# What a node may do, cluster-wide and to its neighbours.
# usage: can-i.sh <node> [other-node]   with KUBECONFIG pointing at the cluster (admin)
# With AS_KUBECONFIG=<the node's own kubeconfig>, asks with that credential
# instead of impersonating it.
set -u
node="$1" other="${2:-}"
ask() {
  if [ -n "${AS_KUBECONFIG:-}" ]; then
    KUBECONFIG="$AS_KUBECONFIG" kubectl auth can-i "$@" 2>/dev/null
  else
    kubectl auth can-i "$@" --as="system:node:$node" \
      --as-group=system:nodes --as-group=system:authenticated 2>/dev/null
  fi
}
for check in "list pods -A" "list secrets -A" "get secrets -n kube-system" \
             "list configmaps -A" "list persistentvolumeclaims -A" \
             "get persistentvolumes" "delete pods -A" "list services -A" \
             "list endpointslices.discovery.k8s.io -A" "list nodes" \
             "patch nodes/$node" "patch nodes/$node --subresource=status"; do
  # shellcheck disable=SC2086 # each check is several words
  printf '  %-44s %s\n' "$check" "$(ask $check)"
done
if [ -n "$other" ]; then
  printf '  %-44s %s\n' "patch nodes/$other" "$(ask patch "nodes/$other")"
fi
