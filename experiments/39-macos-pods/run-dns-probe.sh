#!/usr/bin/env bash
# Runs dns-probe.yaml's four pods on the macOS machine and prints each one's
# answer. Assumes run-macos-machine.sh left mac-0 up.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
state=$("$here/../../ferry" profile | awk '$1 == "state" {print $2}')
export KUBECONFIG="$state/admin.conf"
pods="${PODS:-dns-probe dns-probe-root dns-probe-nochroot dns-probe-both}"
kubectl delete pod $pods --ignore-not-found >/dev/null 2>&1
kubectl apply -f "$here/${PROBES:-dns-probe.yaml}" >/dev/null
for p in $pods; do
    for _ in $(seq "${WAIT:-60}"); do
        case "$(kubectl get pod "$p" -o jsonpath='{.status.phase}')" in Succeeded|Failed) break ;; esac
        sleep 1
    done
    echo "--- $p"
    kubectl logs "$p" 2>&1 | sed 's/^/    /'
done
kubectl delete pod $pods --wait=false >/dev/null 2>&1
