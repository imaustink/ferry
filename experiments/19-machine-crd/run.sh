#!/usr/bin/env bash
# Milestone 2: a node made by applying a resource, and unmade by deleting it.
#
# The same machine experiment 18 booted by hand, now reconciled by
# ferry-machined from a Machine object. What is being tested is the loop rather
# than the VM: apply, watch a node appear and go Ready, delete, watch it go.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
image_dir="$root/experiments/18-node-image"

STATE="${STATE:-${TMPDIR:-/tmp}/machine-crd}"
API_PORT="${API_PORT:-18643}"
export KUBECONFIG="$STATE/admin.conf"
LAN_IP="${LAN_IP:-$(ipconfig getifaddr en0 2>/dev/null || echo 127.0.0.1)}"
KERNEL="${KERNEL:-$root/kernel/vmlinux-arm64}"
[ -f "$KERNEL" ] || KERNEL="$HOME/ferry/kernel/vmlinux-arm64"

machined_pid=""
cleanup() {
  [ -n "$machined_pid" ] && kill "$machined_pid" 2>/dev/null
  pkill -f "ferry-node run --disk $STATE" 2>/dev/null
  [ "${KEEP:-0}" = 1 ] && return 0
  STATE="$STATE" "$root/control-plane/down.sh" >/dev/null 2>&1
}
trap cleanup EXIT

[ -x "$root/bin/ferry-machined" ] || { echo "build ferry-machined first"; exit 1; }
[ -f "$image_dir/build/node.ext4" ] || { echo "run 18-node-image/build.sh first"; exit 1; }

echo "==> control plane"
rm -rf "$STATE"; mkdir -p "$STATE"
STATE="$STATE" PKI_DIR="$STATE/pki" NODE_NAME=cp-node ADVERTISE="$LAN_IP" \
  POD_GATEWAY="$LAN_IP" API_PORT="$API_PORT" \
  CONTROLLER_PORT=18657 SCHEDULER_PORT=18659 \
  ETCD_CLIENT_PORT=18779 ETCD_PEER_PORT=18780 \
  "$root/control-plane/up.sh" >"$STATE/up.log" 2>&1 \
  || { echo "control plane failed"; tail -20 "$STATE/up.log"; exit 1; }

echo "==> CRD and addons"
kubectl apply -f "$root/ferry-machined/crd.yaml" >/dev/null
DNS_SERVICE_IP=10.96.0.10
sed -e "s|__APISERVER_HOST__|$LAN_IP|g" -e "s|__APISERVER_PORT__|$API_PORT|g" \
    -e "s|__CLUSTER_CIDR__|10.88.0.0/16|g" \
    -e "s|__KUBE_PROXY_IMAGE__|registry.k8s.io/kube-proxy:v1.34.11|g" \
    "$image_dir/manifests/kube-proxy.yaml" | kubectl apply -f - >/dev/null
sed -e "s|__APISERVER_HOST__|$LAN_IP|g" -e "s|__APISERVER_PORT__|$API_PORT|g" \
    -e "s|__COREDNS_IMAGE__|docker.io/coredns/coredns:1.11.3|g" \
    -e "s|__CLUSTER_DOMAIN__|cluster.local|g" -e "s|__UPSTREAM_DNS__|1.1.1.1|g" \
    -e "s|__DNS_SERVICE_IP__|$DNS_SERVICE_IP|g" \
    "$image_dir/manifests/coredns.yaml" | kubectl apply -f - >/dev/null

echo "==> ferry-machined"
"$root/bin/ferry-machined" \
  --kubeconfig "$KUBECONFIG" \
  --ferry-node "$image_dir/build/ferry-node" \
  --kernel "$KERNEL" \
  --image "$image_dir/build/node.ext4" \
  --state "$STATE" \
  --api-server "https://$LAN_IP:$API_PORT" \
  --ca "$STATE/pki/ca.crt" \
  --cluster-dns "$DNS_SERVICE_IP" \
  >"$STATE/machined.log" 2>&1 &
machined_pid=$!
sleep 2

echo
echo "==> applying a Machine"
applied=$(python3 -c 'import time; print(time.time())')
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: ferry.dev/v1alpha1
kind: Machine
metadata:
  name: worker-0
spec:
  cpus: 2
  memory: 2Gi
YAML
kubectl get machines 2>&1 | head -3

ready=""
for _ in $(seq 1 180); do
  if [ "$(kubectl get node worker-0 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]; then
    ready="$(python3 -c "import time; print(f'{time.time() - $applied:.1f}')")"
    break
  fi
  sleep 1
done

# One more tick, so the phase reported is the settled one rather than whatever
# was true at the instant the node went Ready.
sleep 3
echo
if [ -n "$ready" ]; then
  echo "APPLY_TO_READY_SECONDS=$ready"
else
  echo "APPLY_TO_READY=never"
  tail -15 "$STATE/machined.log"
fi
kubectl get machines 2>&1 | head -3
kubectl get nodes 2>&1 | head -3

if [ "${KEEP:-0}" = 1 ]; then
  echo; echo "left running: export KUBECONFIG=$KUBECONFIG"
  wait $machined_pid
  exit 0
fi

echo
echo "==> deleting the Machine"
removed=$(python3 -c 'import time; print(time.time())')
kubectl delete machine worker-0 --wait=true --timeout=120s >/dev/null 2>&1
gone=""
for _ in $(seq 1 120); do
  if ! kubectl get node worker-0 >/dev/null 2>&1; then
    gone="$(python3 -c "import time; print(f'{time.time() - $removed:.1f}')")"
    break
  fi
  sleep 1
done
[ -n "$gone" ] && echo "DELETE_TO_GONE_SECONDS=$gone" || echo "DELETE_TO_GONE=never"
# 2>/dev/null, because "No resources found" goes to stderr and counting it as
# a line says one machine is left when none is.
echo "machines left: $(kubectl get machines --no-headers 2>/dev/null | wc -l | tr -d ' ')  nodes named worker-0: $(kubectl get nodes --no-headers 2>/dev/null | grep -c worker-0)"
pgrep -f "ferry-node run --disk $STATE" >/dev/null && echo "VM_STILL_RUNNING" || echo "VM_STOPPED"
