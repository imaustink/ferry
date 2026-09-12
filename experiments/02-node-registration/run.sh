#!/usr/bin/env bash
# Registers the Mac itself as a Kubernetes node against the native control
# plane. The runtime underneath is still the fake from experiment 01 -- this
# tests the kubelet/API-server half of the architecture, not the hypervisor.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/../.."
STATE="${STATE:-/tmp/ferry}"
NODE_NAME="${NODE_NAME:-ferry-mac}"
run="${RUNDIR:-/tmp/ferry-e02}"
sock=/tmp/ferry-fakecri.sock

rm -rf "$run"; mkdir -p "$run/kubelet" "$run/pki" "$run/podlogs" "$run/containerlogs" "$run/volume-plugins"

cat > "$run/kubelet.yaml" <<YAML
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
podLogsDir: $run/podlogs
containerRuntimeEndpoint: unix://$sock
imageServiceEndpoint: unix://$sock
# The default plugin directory is /usr/libexec/kubernetes, which macOS does not
# permit creating even as root under SIP.
volumePluginDir: $run/volume-plugins
# The upstream hard-eviction defaults (nodefs.available<10%, imagefs<15%) are
# sized for small cloud nodes. On a 926 GB laptop disk, 15% is 139 GB that must
# sit idle or the node taints itself NoSchedule. Percentages that mean something
# at this scale.
evictionHard:
  memory.available: "500Mi"
  nodefs.available: "5%"
  imagefs.available: "5%"
  nodefs.inodesFree: "5%"
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

FERRY_CONTAINER_LOGS_DIR="$run/containerlogs" \
"$root/bin/kubelet" \
  --config="$run/kubelet.yaml" \
  --kubeconfig="$STATE/kubelet.conf" \
  --hostname-override="$NODE_NAME" \
  --root-dir="$run/kubelet" \
  --cert-dir="$run/pki" \
  --v=2 >"$run/kubelet.log" 2>&1 &
echo $! > "$run/kubelet.pid"
echo "kubelet pid $(cat "$run/kubelet.pid"), logs in $run"
