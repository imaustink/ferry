#!/usr/bin/env bash
# A node image, booted as a machine, joining a cluster.
#
# The difference from experiment 17 is the packaging, and the packaging is the
# point: this VM boots its own init from its own disk, owns a writable /proc,
# carries iptables, and is sized as a node rather than as a container. Nothing
# is staged into it at run time.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"

STATE="${STATE:-${TMPDIR:-/tmp}/node-image}"
API_PORT="${API_PORT:-18543}"
NODE_NAME="${NODE_NAME:-ferry-node-img}"
DISK="${DISK:-$here/build/node.ext4}"
KERNEL="${KERNEL:-$root/kernel/vmlinux-arm64}"
[ -f "$KERNEL" ] || KERNEL="$HOME/ferry/kernel/vmlinux-arm64"
export KUBECONFIG="$STATE/admin.conf"

LAN_IP="${LAN_IP:-$(ipconfig getifaddr en0 2>/dev/null || echo 127.0.0.1)}"

cleanup() {
  [ -n "${node_pid:-}" ] && kill "$node_pid" 2>/dev/null
  [ "${KEEP:-0}" = 1 ] && return 0
  STATE="$STATE" "$root/control-plane/down.sh" >/dev/null 2>&1
}
trap cleanup EXIT

echo "==> control plane on the Mac ($LAN_IP:$API_PORT)"
rm -rf "$STATE"; mkdir -p "$STATE"
STATE="$STATE" PKI_DIR="$STATE/pki" NODE_NAME=cp-node ADVERTISE="$LAN_IP" \
  POD_GATEWAY="$LAN_IP" API_PORT="$API_PORT" \
  CONTROLLER_PORT=18557 SCHEDULER_PORT=18559 \
  ETCD_CLIENT_PORT=18679 ETCD_PEER_PORT=18680 \
  "$root/control-plane/up.sh" >"$STATE/up.log" 2>&1 \
  || { echo "control plane failed"; tail -20 "$STATE/up.log"; exit 1; }

TOKEN_ID="$(head -c 3 /dev/urandom | xxd -p | head -c 6)"
TOKEN_SECRET="$(head -c 8 /dev/urandom | xxd -p | head -c 16)"
TOKEN="$TOKEN_ID.$TOKEN_SECRET"
kubectl create secret generic "bootstrap-token-$TOKEN_ID" \
  --namespace kube-system --type bootstrap.kubernetes.io/token \
  --from-literal=token-id="$TOKEN_ID" \
  --from-literal=token-secret="$TOKEN_SECRET" \
  --from-literal=usage-bootstrap-authentication=true \
  --from-literal=usage-bootstrap-signing=true \
  --from-literal=auth-extra-groups=system:bootstrappers:ferry:default-node-token >/dev/null
kubectl create clusterrolebinding ferry-node-bootstrap \
  --clusterrole=system:node-bootstrapper \
  --group=system:bootstrappers:ferry:default-node-token >/dev/null
kubectl create clusterrolebinding ferry-node-autoapprove \
  --clusterrole=system:certificates.k8s.io:certificatesigningrequests:nodeclient \
  --group=system:bootstrappers:ferry:default-node-token >/dev/null
kubectl create clusterrolebinding ferry-node-autoapprove-renew \
  --clusterrole=system:certificates.k8s.io:certificatesigningrequests:selfnodeclient \
  --group=system:nodes >/dev/null

# Each run gets its own copy: the node writes to its root filesystem, and a
# machine is meant to be thrown away rather than reset.
run_disk="$STATE/node.ext4"
cp -c "$DISK" "$run_disk" 2>/dev/null || cp "$DISK" "$run_disk"

echo "==> booting $NODE_NAME"
node_start=$(python3 -c 'import time; print(time.time())')
"$here/build/ferry-node" run \
  --disk "$run_disk" \
  --kernel "$KERNEL" \
  --ca "$STATE/pki/ca.crt" \
  --node-name "$NODE_NAME" \
  --api-server "https://$LAN_IP:$API_PORT" \
  --token "$TOKEN" \
  --memory-mib "${MEMORY_MIB:-2048}" \
  --cluster-dns "${DNS_SERVICE_IP:-10.96.0.10}" \
  >"$STATE/node.log" 2>&1 &
node_pid=$!

# Cluster addons, applied while the machine boots. kube-proxy first: nothing
# answers a ClusterIP until it has programmed the node, and cluster DNS is
# reached through one.
DNS_SERVICE_IP="${DNS_SERVICE_IP:-10.96.0.10}"
KUBE_PROXY_IMAGE="${KUBE_PROXY_IMAGE:-registry.k8s.io/kube-proxy:v1.34.11}"
COREDNS_IMAGE="${COREDNS_IMAGE:-docker.io/coredns/coredns:1.11.3}"
UPSTREAM_DNS="${UPSTREAM_DNS:-1.1.1.1}"
render() { # file
  sed -e "s|__APISERVER_HOST__|$LAN_IP|g" \
      -e "s|__APISERVER_PORT__|$API_PORT|g" \
      -e "s|__CLUSTER_CIDR__|10.88.0.0/16|g" \
      -e "s|__KUBE_PROXY_IMAGE__|$KUBE_PROXY_IMAGE|g" \
      -e "s|__COREDNS_IMAGE__|$COREDNS_IMAGE|g" \
      -e "s|__CLUSTER_DOMAIN__|cluster.local|g" \
      -e "s|__UPSTREAM_DNS__|$UPSTREAM_DNS|g" \
      -e "s|__DNS_SERVICE_IP__|$DNS_SERVICE_IP|g" \
      "$1"
}
render "$here/manifests/kube-proxy.yaml" | kubectl apply -f - >/dev/null
render "$here/manifests/coredns.yaml" | kubectl apply -f - >/dev/null
echo "==> kube-proxy and CoreDNS applied (cluster DNS $DNS_SERVICE_IP)"

ready_seconds=""
for _ in $(seq 1 240); do
  if [ "$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]; then
    ready_seconds="$(python3 -c "import time; print(f'{time.time() - $node_start:.1f}')")"
    break
  fi
  kill -0 $node_pid 2>/dev/null || { echo "the node process exited"; tail -20 "$STATE/node.log"; exit 1; }
  sleep 1
done

sed -n 's/^    ferry-node: /    /p' "$STATE/node.log" | head -8
echo
if [ -n "$ready_seconds" ]; then
  echo "BOOT_TO_READY_SECONDS=$ready_seconds"
  kubectl get nodes -o wide
else
  echo "BOOT_TO_READY=never"
  tail -25 "$STATE/node.log"
  kubectl get csr 2>&1 | head -4
fi

[ "${KEEP:-0}" = 1 ] && { echo; echo "left running: export KUBECONFIG=$KUBECONFIG"; wait $node_pid; }
