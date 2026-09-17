#!/usr/bin/env bash
# What a node is supposed to be able to do, checked rather than assumed.
#
# Run against a cluster left up by `KEEP=1 ./run.sh`. Each check prints PASS or
# FAIL and the script's exit status is the verdict, so this can gate a change.
set -uo pipefail
STATE="${STATE:-${TMPDIR:-/tmp}/node-image}"
export KUBECONFIG="$STATE/admin.conf"
NODE_NAME="${NODE_NAME:-ferry-node-img}"
failures=0

check() { # name result
  if [ "$2" = pass ]; then printf '  PASS  %s\n' "$1"
  else printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); fi
}

waitfor() { # seconds command...
  local deadline=$(( $(date +%s) + $1 )); shift
  while [ "$(date +%s)" -lt "$deadline" ]; do
    "$@" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

echo "==> node"
waitfor 120 sh -c "kubectl get node $NODE_NAME -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True" \
  && check "node is Ready" pass || check "node is Ready" fail

echo "==> addons"
waitfor 240 sh -c "kubectl -n kube-system get pods -l k8s-app=kube-proxy -o jsonpath='{.items[0].status.phase}' | grep -q Running" \
  && check "kube-proxy is Running" pass || check "kube-proxy is Running" fail
waitfor 240 sh -c "kubectl -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{.items[0].status.conditions[?(@.type==\"Ready\")].status}' | grep -q True" \
  && check "CoreDNS is Ready" pass || check "CoreDNS is Ready" fail

echo "==> workload"
kubectl delete pod probe --ignore-not-found >/dev/null 2>&1
# One pod that answers every remaining question: does DNS resolve a Service
# name, does a ClusterIP actually route, and can a pod still reach the world.
kubectl run probe --image=public.ecr.aws/docker/library/alpine:3.20 --restart=Never --command -- \
  sh -c '
    nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1 && echo DNS_CLUSTER_OK || echo DNS_CLUSTER_FAIL
    nslookup example.com >/dev/null 2>&1 && echo DNS_EXTERNAL_OK || echo DNS_EXTERNAL_FAIL
    wget -qO- -T 10 --no-check-certificate https://kubernetes.default.svc.cluster.local/healthz 2>/dev/null | grep -q ok \
      && echo CLUSTERIP_OK || echo CLUSTERIP_FAIL
    wget -qO- -T 10 http://1.1.1.1 >/dev/null 2>&1 && echo EGRESS_OK || echo EGRESS_FAIL
    sleep 300' >/dev/null 2>&1

waitfor 180 sh -c "kubectl get pod probe -o jsonpath='{.status.phase}' | grep -qE 'Running|Succeeded'" \
  && check "probe pod runs" pass || check "probe pod runs" fail
sleep 12
logs="$(kubectl logs probe 2>/dev/null)"
printf '%s\n' "$logs" | sed 's/^/        /'

for want in DNS_CLUSTER_OK DNS_EXTERNAL_OK CLUSTERIP_OK EGRESS_OK; do
  printf '%s' "$logs" | grep -q "$want" && check "$want" pass || check "$want" fail
done

echo
if [ "$failures" -eq 0 ]; then echo "all checks passed"; else echo "$failures check(s) failed"; fi
exit "$failures"
