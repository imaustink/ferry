#!/usr/bin/env bash
# The identities an upgrade must not change, one line each, so two runs diff:
# every object workload.yaml made by kind/name and uid, and every pod's name,
# IP, restarts and start time.
#
#   KUBECONFIG=... ./snapshot-state.sh > before.txt
set -uo pipefail
for kind in customresourcedefinition/widgets.example.dev secret/upgrade-secret lease/upgrade-lease \
            deployment/web deployment/client service/web poddisruptionbudget/web widget/w1; do
  printf '%s %s\n' "$kind" "$(kubectl get "$kind" -o jsonpath='{.metadata.uid}' 2>&1)"
done
kubectl get secret upgrade-secret -o jsonpath='secret-data {.data.token}{"\n"}'
kubectl get widget w1 -o jsonpath='widget-spec {.spec.size}{"\n"}'
kubectl get pods -o jsonpath='{range .items[*]}pod {.metadata.name} {.status.podIP} restarts={.status.containerStatuses[0].restartCount} started={.status.startTime} node={.spec.nodeName}{"\n"}{end}'
