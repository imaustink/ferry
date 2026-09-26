#!/usr/bin/env bash
# Rebuild everything a macOS machine is made from, with nothing declared:
# stop mode 2, rebuild ferry-node, ferry-machined and ferry-karpenter, re-bake
# golden-node, start mode 2 again.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
state=$("$repo/ferry" profile | awk '$1 == "state" {print $2}')
export KUBECONFIG="$state/admin.conf"

kubectl delete machine --all --timeout=120s >/dev/null 2>&1
"$here/machines-on.sh" disable >/dev/null 2>&1
(cd "$repo/experiments/18-node-image" && OUT="$repo/bin/ferry-node" ./rebuild-tool.sh 2>&1 | tail -1)
(cd "$repo/ferry-machined" && go build -o "$repo/bin/ferry-machined" .) && echo "ferry-machined built"
(cd "$repo/ferry-karpenter" && go build -o "$repo/bin/ferry-karpenter" .) && echo "ferry-karpenter built"
UPDATE=1 "$here/bake-macos-node.sh" 2>&1 | grep -E "baked|SIP|error"
kubectl apply -f "$repo/ferry-machined/crd.yaml" >/dev/null
"$here/machines-on.sh" 2>&1 | grep -E "machine network|machines are|✗"
kubectl get nodepools
