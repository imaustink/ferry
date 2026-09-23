#!/usr/bin/env bash
# Everything experiment 37 checks, on a cluster with a 'ferry up' node, two
# 'ferry node add' nodes and a second profile joined to it.
# usage: run.sh <first> <added> <added> <joined> <joined-kubeconfig>
#        with KUBECONFIG pointing at the cluster (admin)
set -u
here="$(cd "$(dirname "$0")" && pwd)"
first="$1" a="$2" b="$3" joined="$4" joined_conf="$5"
home="$(dirname "$KUBECONFIG")"
echo "## bindings"
for binding in ferry:system-nodes ferry-node-proxier; do
  printf '  %-22s %s\n' "$binding" "$(kubectl get clusterrolebinding "$binding" \
    -o jsonpath='{.roleRef.name}' 2>/dev/null || echo absent)"
done
echo "## what each node may do"
"$here/all-nodes.sh" "$first=$home/kubelet.conf" "$a=$home/pki/nodes/$a.conf" \
  "$b=$home/pki/nodes/$b.conf" "$joined=$joined_conf"
echo "## what each node may change (NodeRestriction)"
KEEP=1 NO_PVC="$joined" "$here/workload.sh" "$first" "$a" "$b" "$joined" > /tmp/e37-workload.txt 2>&1
"$here/writes.sh" "$a" "$home/pki/nodes/$a.conf" "$b"
"$here/writes.sh" "$joined" "$joined_conf" "$first"
echo "## pods on every node"
cat /tmp/e37-workload.txt
echo "## from the joined node's pod"
"$here/from-pod.sh" e37-3 e37-0 e37-1
echo "## from an added node's pod"
"$here/from-pod.sh" e37-1 e37-3 e37-2
echo "## NetworkPolicy"
"$here/../34-join-policy/policy.sh" "$joined" "$a" 37991
"$here/../34-join-policy/policy.sh" "$a" "$first" 37992
