#!/usr/bin/env bash
# The whole stack, for real: native control plane, patched darwin kubelet, and
# ferry-cri giving every pod its own virtual machine. No fake runtime.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/../.."
STATE="${STATE:-/tmp/ferry}"
NODE_NAME="${NODE_NAME:-ferry-mac}"
run="${RUNDIR:-/tmp/ferry-e05}"
sock=/tmp/ferry-cri.sock
POD_SUBNET="${POD_SUBNET:-192.168.66.1/24}"

rm -rf "$run"; mkdir -p "$run/kubelet" "$run/pki" "$run/podlogs" "$run/containerlogs" "$run/volume-plugins"

echo "==> ferry-cri"
# A socket file left behind by a previous run makes the readiness check below
# pass instantly, and the kubelet then dials a socket nothing is listening on.
rm -f "$sock"
"$root/bin/ferry-cri" \
  --endpoint "$sock" \
  --state "$run/cri" \
  --kernel "$root/experiments/03-vm-ceiling/assets/vmlinux-arm64" \
  --pod-subnet "$POD_SUBNET" \
  >"$run/ferry-cri.log" 2>&1 &
echo $! > "$run/ferry-cri.pid"

# Existence of the socket is not readiness -- wait until the log says it is
# serving, which is emitted after the listener is bound.
ready=
for _ in $(seq 1 90); do
  if [ -S "$sock" ] && grep -q "serving" "$run/ferry-cri.log" 2>/dev/null; then ready=1; break; fi
  if ! kill -0 "$(cat "$run/ferry-cri.pid")" 2>/dev/null; then break; fi
  sleep 1
done
if [ -z "$ready" ]; then
  echo "ferry-cri did not come up:" >&2; tail -5 "$run/ferry-cri.log" >&2; exit 1
fi
sed -n '2,8p' "$run/ferry-cri.log" | sed 's/^/    /'

# The API server must advertise the gateway of the subnet ferry-cri actually
# obtained, which is not necessarily the one requested -- leaked vmnet networks
# force a fallback. ferry-cri publishes the gateway it settled on.
POD_GATEWAY="$(cat "$run/cri/gateway" 2>/dev/null || echo "")"
if [ -z "$POD_GATEWAY" ]; then echo "ferry-cri did not publish a gateway" >&2; exit 1; fi
echo "==> control plane (advertising $POD_GATEWAY)"
STATE="$STATE" POD_GATEWAY="$POD_GATEWAY" "$root/control-plane/up.sh" >"$run/control-plane.log" 2>&1 || {
  echo "control plane failed; see $run/control-plane.log" >&2; exit 1; }

cat > "$run/kubelet.yaml" <<YAML
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
podLogsDir: $run/podlogs
containerRuntimeEndpoint: unix://$sock
imageServiceEndpoint: unix://$sock
volumePluginDir: $run/volume-plugins
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
# A pod is a VM here, and a VM takes longer to appear than a container does.
runtimeRequestTimeout: 10m
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

echo "==> kubelet"
FERRY_CONTAINER_LOGS_DIR="$run/containerlogs" \
"$root/bin/kubelet" \
  --config="$run/kubelet.yaml" \
  --kubeconfig="$STATE/kubelet.conf" \
  --hostname-override="$NODE_NAME" \
  --root-dir="$run/kubelet" \
  --cert-dir="$run/pki" \
  --v=2 >"$run/kubelet.log" 2>&1 &
echo $! > "$run/kubelet.pid"

echo "==> up; logs in $run"
echo "    export KUBECONFIG=$STATE/admin.conf"
