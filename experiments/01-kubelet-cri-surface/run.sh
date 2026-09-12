#!/usr/bin/env bash
# Drives the darwin kubelet against the fake CRI in standalone mode (no API
# server) and captures how far it gets. The run directory lives under /tmp
# because macOS caps unix socket paths at ~104 bytes and the kubelet builds
# its podresources socket path under --root-dir.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/../.."
run="${RUNDIR:-/tmp/k5s-e01}"
secs="${SECS:-45}"
sock=/tmp/k5s-fakecri.sock

rm -rf "$run"; mkdir -p "$run/kubelet" "$run/pki" "$run/podlogs" "$run/volume-plugins" "$run/containerlogs" "$run/volume-plugins"

cat > "$run/kubelet.yaml" <<YAML
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
staticPodPath: $here/manifests
podLogsDir: $run/podlogs
containerRuntimeEndpoint: unix://$sock
imageServiceEndpoint: unix://$sock
# No cgroup hierarchy exists on the host, so every knob that would program one
# is disabled rather than left to fail at runtime.
# The default plugin directory is /usr/libexec/kubernetes, which macOS does not
# permit creating even as root under SIP.
volumePluginDir: $run/volume-plugins
cgroupsPerQOS: false
enforceNodeAllocatable: []
failSwapOn: false
address: 127.0.0.1
readOnlyPort: 0
authentication:
  anonymous:
    enabled: true
  webhook:
    enabled: false
authorization:
  mode: AlwaysAllow
YAML

"$root/bin/fakecri" -endpoint "$sock" >"$run/fakecri.log" 2>&1 &
cri=$!
sleep 1

K5S_CONTAINER_LOGS_DIR="$run/containerlogs" \
"$root/bin/kubelet" \
  --config="$run/kubelet.yaml" \
  --root-dir="$run/kubelet" \
  --cert-dir="$run/pki" \
  --v=2 >"$run/kubelet.log" 2>&1 &
kubelet=$!

sleep "$secs"
kill -TERM $kubelet 2>/dev/null; wait $kubelet 2>/dev/null
kill -INT  $cri     2>/dev/null; wait $cri     2>/dev/null
echo "logs in $run"
