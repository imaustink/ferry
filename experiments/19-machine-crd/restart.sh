#!/usr/bin/env bash
# A controller restart is not an event in a machine's life.
#
# Review of PR #42 found that it was: shutdown() removed every spec file, so
# ferry-node serve stopped every VM, and on the way back up an empty in-memory
# map made reconcile treat each Machine as new -- removing the live disk,
# cloning the image over it, and minting a fresh bootstrap token. The finalizer
# exists so a VM outlives control-plane churn; this checks the other half.
#
# It also checks spec.disk, which used to be parsed, logged and ignored, and is
# now refused when the image cannot deliver it.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
image_dir="$root/experiments/18-node-image"

STATE="${STATE:-${TMPDIR:-/tmp}/machine-restart}"
API_PORT="${API_PORT:-18653}"
export KUBECONFIG="$STATE/admin.conf"
LAN_IP="${LAN_IP:-$(ipconfig getifaddr en0 2>/dev/null || echo 127.0.0.1)}"
KERNEL="${KERNEL:-$root/kernel/vmlinux-arm64}"
[ -f "$KERNEL" ] || KERNEL="$HOME/ferry/kernel/vmlinux-arm64"
DNS_SERVICE_IP=10.96.0.10
DISK_GI=12

failures=0
check() { # name result
  if [ "$2" = pass ]; then printf '  PASS  %s\n' "$1"
  else printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); fi
}

machined_pid=""; serve_pid=""
cleanup() {
  [ -n "$machined_pid" ] && kill "$machined_pid" 2>/dev/null
  [ -n "$serve_pid" ] && kill "$serve_pid" 2>/dev/null
  sleep 1
  pkill -f "ferry-node serve --dir $STATE" 2>/dev/null
  [ "${KEEP:-0}" = 1 ] && return 0
  STATE="$STATE" "$root/control-plane/down.sh" >/dev/null 2>&1
}
trap cleanup EXIT

[ -x "$root/bin/ferry-machined" ] || { echo "build ferry-machined first"; exit 1; }
[ -f "$image_dir/build/node.ext4" ] || { echo "run 18-node-image/build.sh first"; exit 1; }

start_machined() { # logfile
  "$root/bin/ferry-machined" \
    --kubeconfig "$KUBECONFIG" \
    --machines "$STATE/machines" \
    --kernel "$KERNEL" \
    --image "$image_dir/build/node.ext4" \
    --state "$STATE" \
    --api-server "https://$LAN_IP:$API_PORT" \
    --ca "$STATE/pki/ca.crt" \
    --cluster-dns "$DNS_SERVICE_IP" \
    >"$STATE/$1" 2>&1 &
  machined_pid=$!
}

echo "==> control plane"
rm -rf "$STATE"; mkdir -p "$STATE/machines"
STATE="$STATE" PKI_DIR="$STATE/pki" NODE_NAME=cp-node ADVERTISE="$LAN_IP" \
  POD_GATEWAY="$LAN_IP" API_PORT="$API_PORT" \
  CONTROLLER_PORT=18667 SCHEDULER_PORT=18669 \
  ETCD_CLIENT_PORT=18789 ETCD_PEER_PORT=18790 \
  "$root/control-plane/up.sh" >"$STATE/up.log" 2>&1 \
  || { echo "control plane failed"; tail -20 "$STATE/up.log"; exit 1; }

kubectl apply -f "$root/ferry-machined/crd.yaml" >/dev/null
sed -e "s|__APISERVER_HOST__|$LAN_IP|g" -e "s|__APISERVER_PORT__|$API_PORT|g" \
    -e "s|__CLUSTER_CIDR__|10.88.0.0/16|g" \
    -e "s|__KUBE_PROXY_IMAGE__|registry.k8s.io/kube-proxy:v1.34.11|g" \
    "$image_dir/manifests/kube-proxy.yaml" | kubectl apply -f - >/dev/null

"$image_dir/build/ferry-node" serve \
  --dir "$STATE/machines" --kernel "$KERNEL" --ca "$STATE/pki/ca.crt" \
  --api-server "https://$LAN_IP:$API_PORT" --cluster-dns "$DNS_SERVICE_IP" \
  >"$STATE/serve.log" 2>&1 &
serve_pid=$!
sleep 3

start_machined machined.log
sleep 2

echo "==> a disk size the image cannot deliver"
kubectl apply -f - >/dev/null <<YAML
apiVersion: ferry.dev/v1alpha1
kind: Machine
metadata:
  name: worker-bad
spec:
  cpus: 2
  memory: 2Gi
  disk: ${DISK_GI}Gi
YAML
phase=""
for _ in $(seq 1 30); do
  phase=$(kubectl get machine worker-bad -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$phase" = Failed ] && break
  sleep 1
done
[ "$phase" = Failed ] \
  && check "a spec.disk the image cannot deliver is refused" pass \
  || check "a spec.disk the image cannot deliver is refused (phase '${phase:-none}')" fail
msg=$(kubectl get machine worker-bad -o jsonpath='{.status.message}' 2>/dev/null)
case "$msg" in
  *"cannot be resized in place"*) check "and it says how to get the size asked for" pass ;;
  *) check "and it says how to get the size asked for (said '${msg:-nothing}')" fail ;;
esac
# Refused before anything is created, so there is nothing to clean up.
[ -f "$STATE/worker-bad.ext4" ] \
  && check "nothing was cloned for it" fail || check "nothing was cloned for it" pass
kubectl delete machine worker-bad --wait=true --timeout=60s >/dev/null 2>&1

echo "==> a machine"
kubectl apply -f - >/dev/null <<YAML
apiVersion: ferry.dev/v1alpha1
kind: Machine
metadata:
  name: worker-0
spec:
  cpus: 2
  memory: 2Gi
YAML

for _ in $(seq 1 180); do
  [ "$(kubectl get node worker-0 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ] && break
  sleep 1
done
[ "$(kubectl get node worker-0 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ] \
  && check "machine reaches Ready" pass || { check "machine reaches Ready" fail; tail -15 "$STATE/machined.log"; exit 1; }

# --- the size it does get is the image's, on both sides ------------------
[ "$(stat -f %z "$STATE/worker-0.ext4")" = "$(stat -f %z "$image_dir/build/node.ext4")" ] \
  && check "the clone is the image's size" pass || check "the clone is the image's size" fail
root_size=$(grep -a -o 'root filesystem [0-9.]*G' "$STATE/serve.log" | tail -1 | sed 's/root filesystem //')
[ -n "$root_size" ] \
  && check "and the node agrees from inside ($root_size)" pass \
  || check "and the node agrees from inside" fail

# --- what must survive a restart -----------------------------------------
disk_inode=$(stat -f %i "$STATE/worker-0.ext4")
token_before=$(python3 -c "import json;print(json.load(open('$STATE/machines/worker-0.json'))['token'])")
node_uid_before=$(kubectl get node worker-0 -o jsonpath='{.metadata.uid}')

echo "==> stopping ferry-machined"
kill -TERM "$machined_pid" 2>/dev/null
for _ in $(seq 1 30); do kill -0 "$machined_pid" 2>/dev/null || break; sleep 1; done
machined_pid=""
sleep 5

[ -f "$STATE/machines/worker-0.json" ] \
  && check "the machine is still asked for" pass || check "the machine is still asked for" fail
grep -q "worker-0 stopping" "$STATE/serve.log" \
  && check "the VM was not torn down" fail || check "the VM was not torn down" pass
[ "$(kubectl get node worker-0 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ] \
  && check "the node stayed Ready with no controller" pass \
  || check "the node stayed Ready with no controller" fail

echo "==> starting it again"
start_machined machined2.log
sleep 8

grep -q "adopted" "$STATE/machined2.log" \
  && check "the new controller adopted the machine" pass \
  || { check "the new controller adopted the machine" fail; tail -10 "$STATE/machined2.log"; }
grep -q "provisioning" "$STATE/machined2.log" \
  && check "it did not re-provision" fail || check "it did not re-provision" pass

# The inode, not the mtime: a running node writes to its own root disk, so
# mtime moving across a restart is correct. A re-clone replaces the file.
[ "$(stat -f %i "$STATE/worker-0.ext4")" = "$disk_inode" ] \
  && check "the root disk was not re-cloned" pass || check "the root disk was not re-cloned" fail
[ "$(python3 -c "import json;print(json.load(open('$STATE/machines/worker-0.json'))['token'])")" = "$token_before" ] \
  && check "the bootstrap token is the same one" pass || check "the bootstrap token is the same one" fail
[ "$(kubectl get node worker-0 -o jsonpath='{.metadata.uid}' 2>/dev/null)" = "$node_uid_before" ] \
  && check "it is the same Node, not a replacement" pass \
  || check "it is the same Node, not a replacement" fail

# --- and delete still works ----------------------------------------------
echo "==> deleting"
kubectl delete machine worker-0 --wait=true --timeout=120s >/dev/null 2>&1
gone=fail
for _ in $(seq 1 120); do
  kubectl get node worker-0 >/dev/null 2>&1 || { gone=pass; break; }
  sleep 1
done
check "deleting the adopted machine still removes it" "$gone"

echo
if [ "$failures" -eq 0 ]; then echo "all checks passed"; else echo "$failures check(s) failed"; fi
exit "$failures"
