#!/usr/bin/env bash
# What NodeRestriction lets a node change, which `can-i` cannot show: it is
# admission, after authorization. Server-side dry runs, so nothing changes.
# usage: writes.sh <node> <its kubeconfig> <other-node>
#        with KUBECONFIG pointing at the cluster (admin)
set -u
node="$1" conf="$2" other="$3"
as() { KUBECONFIG="$conf" kubectl "$@" --dry-run=server 2>&1 | tail -1 | cut -c1-150; }
pod_on() { kubectl get pods -A --field-selector "spec.nodeName=$1" --no-headers \
             -o custom-columns=N:.metadata.namespace,P:.metadata.name 2>/dev/null | head -1; }
printf '  %-34s %s\n' "label its own Node" "$(as label node "$node" e37=probe --overwrite)"
printf '  %-34s %s\n' "label $other" "$(as label node "$other" e37=probe --overwrite)"
printf '  %-34s %s\n' "annotate $other" "$(as annotate node "$other" e37=probe --overwrite)"
read -r ns pod <<<"$(pod_on "$other")"
[ -n "${pod:-}" ] && printf '  %-34s %s\n' "delete a pod on $other" "$(as delete pod -n "$ns" "$pod")"
read -r ns pod <<<"$(pod_on "$node")"
if [ -n "${pod:-}" ]; then
  printf '  %-34s %s\n' "delete a pod on itself" "$(as delete pod -n "$ns" "$pod")"
fi
