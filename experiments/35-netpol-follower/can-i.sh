#!/usr/bin/env bash
# What a node's own credential may read, cluster-wide.
# usage: can-i.sh <node>   with KUBECONFIG pointing at the cluster (admin)
set -u
node="$1"
for check in "list pods" "list networkpolicies" "list namespaces" "list secrets" "get secrets"; do
  printf '  %-22s %s\n' "$check" \
    "$(kubectl auth can-i $check --all-namespaces --as="system:node:$node" --as-group=system:nodes 2>/dev/null)"
done
printf '  %-22s %s\n' "ClusterRole ferry-node-netpol" \
  "$(kubectl get clusterrole ferry-node-netpol -o name 2>/dev/null || echo absent)"
printf '  %-22s %s\n' "ferry-node-netpol binding" \
  "$(kubectl get clusterrolebinding ferry-node-netpol -o name 2>/dev/null || echo absent)"
