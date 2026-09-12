#!/usr/bin/env bash
# Registers the Mac itself as a Kubernetes node against the native control
# plane. The runtime underneath is still the fake from experiment 01 -- this
# tests the kubelet/API-server half of the architecture, not the hypervisor.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/../.."
STATE="${STATE:-/tmp/k5s}"
NODE_NAME="${NODE_NAME:-k5s-mac}"
run="${RUNDIR:-/tmp/k5s-e02}"
sock=/tmp/k5s-fakecri.sock

rm -rf "$run"; mkdir -p "$run/kubelet" "$run/pki" "$run/podlogs" "$run/containerlogs"

cat > "$run/kubelet.yaml" <<YAML
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
podLogsDir: $run/podlogs
containerRuntimeEndpoint: unix://$sock
imageServiceEndpoint: unix://$sock
cgroupsPerQOS: false
enforceNodeAllocatable: []
failSwapOn: false
readOnlyPort: 0
clusterDomain: cluster.local
authentication:
  x509:
    clientCAFile: $STATE/pki/ca.crt
  anonymous:
    enabled: false
  webhook:
    enabled: true
authorization:
  mode: Webhook
YAML

"$root/bin/fakecri" -endpoint "$sock" -log-repeats 1 >"$run/fakecri.log" 2>&1 &
echo $! > "$run/fakecri.pid"
sleep 1

K5S_CONTAINER_LOGS_DIR="$run/containerlogs" \
"$root/bin/kubelet" \
  --config="$run/kubelet.yaml" \
  --kubeconfig="$STATE/kubelet.conf" \
  --hostname-override="$NODE_NAME" \
  --root-dir="$run/kubelet" \
  --cert-dir="$run/pki" \
  --v=2 >"$run/kubelet.log" 2>&1 &
echo $! > "$run/kubelet.pid"
echo "kubelet pid $(cat "$run/kubelet.pid"), logs in $run"
