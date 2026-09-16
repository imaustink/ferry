#!/usr/bin/env bash
# Milestone 1: a Linux node VM that boots and joins, and how long that takes.
#
# The control plane is ferry's own, running natively on the Mac. The node is a
# VM booted through ferry-cri -- which is the packaging this experiment is
# honest about: it is not yet a purpose-built node image, it is a machine with
# the node's software staged into it. The kernel, the hypervisor, containerd,
# the CNI and the kubelet are all real, and the number being measured is how
# long the whole sequence takes.
#
# boot-to-Ready is the number the provisioner design rests on: single-digit
# seconds means nodes are disposable and consolidation can be aggressive; a
# minute means warm pools and a different design.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
harness="$here/../13-shared-kernel-cost"

STATE="${STATE:-${TMPDIR:-/tmp}/node-vm}"
API_PORT="${API_PORT:-18443}"
NODE_NAME="${NODE_NAME:-ferry-node-1}"
export KUBECONFIG="$STATE/admin.conf"

# The node VM reaches the Mac over its vmnet gateway's network. The LAN address
# is the one that works from any vmnet subnet, and is what ferry advertises for
# the same reason.
LAN_IP="${LAN_IP:-$(ipconfig getifaddr en0 2>/dev/null || echo 127.0.0.1)}"

step() { printf '\n==> %s\n' "$1"; }

cleanup() {
  [ "${KEEP:-0}" = 1 ] && return 0
  "$harness/runtime.sh" stop >/dev/null 2>&1
  STATE="$STATE" "$root/control-plane/down.sh" >/dev/null 2>&1
}
trap cleanup EXIT

step "control plane on the Mac (advertise $LAN_IP:$API_PORT)"
rm -rf "$STATE"; mkdir -p "$STATE"
STATE="$STATE" PKI_DIR="$STATE/pki" NODE_NAME=cp-node ADVERTISE="$LAN_IP" \
  POD_GATEWAY="$LAN_IP" API_PORT="$API_PORT" \
  CONTROLLER_PORT=18257 SCHEDULER_PORT=18259 \
  ETCD_CLIENT_PORT=18379 ETCD_PEER_PORT=18380 \
  "$root/control-plane/up.sh" >"$STATE/up.log" 2>&1 \
  || { echo "control plane failed"; tail -20 "$STATE/up.log"; exit 1; }
kubectl get --raw /healthz && echo

step "bootstrap token and the RBAC a joining node needs"
TOKEN_ID="$(head -c 3 /dev/urandom | xxd -p | head -c 6)"
TOKEN_SECRET="$(head -c 8 /dev/urandom | xxd -p | head -c 16)"
TOKEN="$TOKEN_ID.$TOKEN_SECRET"
kubectl create secret generic "bootstrap-token-$TOKEN_ID" \
  --namespace kube-system --type bootstrap.kubernetes.io/token \
  --from-literal=token-id="$TOKEN_ID" \
  --from-literal=token-secret="$TOKEN_SECRET" \
  --from-literal=usage-bootstrap-authentication=true \
  --from-literal=usage-bootstrap-signing=true \
  --from-literal=auth-extra-groups=system:bootstrappers:ferry:default-node-token \
  >/dev/null
# A bootstrapping kubelet may create a CSR, and its CSR is approved
# automatically; once it has a certificate it may rotate it.
kubectl create clusterrolebinding ferry-node-bootstrap \
  --clusterrole=system:node-bootstrapper \
  --group=system:bootstrappers:ferry:default-node-token >/dev/null
kubectl create clusterrolebinding ferry-node-autoapprove \
  --clusterrole=system:certificates.k8s.io:certificatesigningrequests:nodeclient \
  --group=system:bootstrappers:ferry:default-node-token >/dev/null
kubectl create clusterrolebinding ferry-node-autoapprove-renew \
  --clusterrole=system:certificates.k8s.io:certificatesigningrequests:selfnodeclient \
  --group=system:nodes >/dev/null
cp "$STATE/pki/ca.crt" "$here/stage/ca.crt"
echo "    token $TOKEN"

step "node VM"
"$harness/runtime.sh" stop >/dev/null 2>&1
sleep 2
POD_MEMORY_MIB="${POD_MEMORY_MIB:-4096}" CRI="$root/bin/ferry-cri" \
  "$harness/runtime.sh" start >/dev/null 2>&1 || { echo "runtime failed"; exit 1; }

script="$here/.scratch/node-rendered.sh"
mkdir -p "$here/.scratch"
{
  echo "NODE_NAME=$NODE_NAME"
  echo "API_SERVER=https://$LAN_IP:$API_PORT"
  echo "BOOTSTRAP_TOKEN=$TOKEN"
  echo "CLUSTER_DNS="
  echo "export NODE_NAME API_SERVER BOOTSTRAP_TOKEN CLUSTER_DNS"
  cat "$here/node.sh"
} >"$script"

# Timed from here: this is the moment a provisioner would have decided it needs
# a node.
node_start=$(python3 -c 'import time; print(time.time())')
"$harness/build/shkcost" \
  -count 1 -shape vm-per-pod -workload custom -privileged \
  -image public.ecr.aws/docker/library/debian:12 \
  -cmd-file "$script" \
  -mount "$here/stage:/opt/node" \
  -log-grep "=" \
  -hold "${HOLD:-180s}" -sample 30s -state shk-cri-state \
  -out "$here/results.json" &
harness_pid=$!

step "waiting for the node to go Ready"
ready_seconds=""
for _ in $(seq 1 240); do
  if [ "$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]; then
    ready_seconds="$(python3 -c "import time; print(f'{time.time() - $node_start:.1f}')")"
    break
  fi
  sleep 1
done

echo
if [ -n "$ready_seconds" ]; then
  echo "BOOT_TO_READY_SECONDS=$ready_seconds"
  kubectl get nodes -o wide
else
  echo "BOOT_TO_READY=never"
  kubectl get nodes 2>&1 | head -5
  kubectl get csr 2>&1 | head -5
fi

wait $harness_pid 2>/dev/null
