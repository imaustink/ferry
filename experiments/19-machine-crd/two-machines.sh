#!/usr/bin/env bash
# Two machines at once, and an edit that should be refused.
#
# run.sh proves one machine works. This asks the questions one machine cannot:
# do two of them get distinct addresses, tokens and disks, and does the API
# server actually enforce that a machine's size cannot change?
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
image_dir="$root/experiments/18-node-image"

STATE="${STATE:-${TMPDIR:-/tmp}/machine-two}"
API_PORT="${API_PORT:-18743}"
export KUBECONFIG="$STATE/admin.conf"
LAN_IP="${LAN_IP:-$(ipconfig getifaddr en0 2>/dev/null || echo 127.0.0.1)}"
KERNEL="${KERNEL:-$root/kernel/vmlinux-arm64}"
[ -f "$KERNEL" ] || KERNEL="$HOME/ferry/kernel/vmlinux-arm64"
failures=0

check() { if [ "$2" = pass ]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); fi; }

machined_pid=""
cleanup() {
  [ -n "$machined_pid" ] && kill "$machined_pid" 2>/dev/null
  pkill -f "ferry-node run --disk $STATE" 2>/dev/null
  STATE="$STATE" "$root/control-plane/down.sh" >/dev/null 2>&1
}
trap cleanup EXIT

echo "==> control plane"
rm -rf "$STATE"; mkdir -p "$STATE"
STATE="$STATE" PKI_DIR="$STATE/pki" NODE_NAME=cp-node ADVERTISE="$LAN_IP" \
  POD_GATEWAY="$LAN_IP" API_PORT="$API_PORT" \
  CONTROLLER_PORT=18757 SCHEDULER_PORT=18759 \
  ETCD_CLIENT_PORT=18879 ETCD_PEER_PORT=18880 \
  "$root/control-plane/up.sh" >"$STATE/up.log" 2>&1 \
  || { echo "control plane failed"; tail -20 "$STATE/up.log"; exit 1; }
kubectl apply -f "$root/ferry-machined/crd.yaml" >/dev/null

"$root/bin/ferry-machined" \
  --kubeconfig "$KUBECONFIG" --ferry-node "$image_dir/build/ferry-node" \
  --kernel "$KERNEL" --image "$image_dir/build/node.ext4" --state "$STATE" \
  --api-server "https://$LAN_IP:$API_PORT" --ca "$STATE/pki/ca.crt" \
  >"$STATE/machined.log" 2>&1 &
machined_pid=$!
sleep 2

echo "==> two machines"
for n in worker-a worker-b; do
  kubectl apply -f - >/dev/null <<YAML
apiVersion: ferry.dev/v1alpha1
kind: Machine
metadata: {name: $n}
spec: {cpus: 2, memory: 2Gi}
YAML
done

both=""
for _ in $(seq 1 240); do
  ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready')
  [ "$ready" -ge 2 ] && { both=yes; break; }
  sleep 2
done
[ -n "$both" ] && check "both machines reach Ready" pass || check "both machines reach Ready" fail
kubectl get machines 2>&1 | head -4

addresses=$(kubectl get machines -o jsonpath='{range .items[*]}{.status.address}{"\n"}{end}' 2>/dev/null | sort -u | grep -c .)
[ "$addresses" -ge 2 ] && check "each machine has its own address" pass || check "each machine has its own address" fail

tokens=$(kubectl -n kube-system get secrets --no-headers 2>/dev/null | grep -c bootstrap-token)
[ "$tokens" -ge 2 ] && check "each machine has its own bootstrap token" pass || check "each machine has its own bootstrap token" fail

disks=$(ls "$STATE"/worker-*.ext4 2>/dev/null | grep -vc config)
[ "$disks" -ge 2 ] && check "each machine has its own disk" pass || check "each machine has its own disk" fail

# The two nodes are on different vmnet networks, which is what milestone 3 has
# to solve; recorded here rather than asserted either way.
echo "      addresses: $(kubectl get machines -o jsonpath='{range .items[*]}{.status.address}{" "}{end}' 2>/dev/null)"

echo "==> an edit that should be refused"
if kubectl patch machine worker-a --type=merge -p '{"spec":{"cpus":4}}' >"$STATE/patch.log" 2>&1; then
  check "editing spec is rejected" fail
else
  grep -q "immutable" "$STATE/patch.log" && check "editing spec is rejected" pass \
    || { check "editing spec is rejected" fail; head -2 "$STATE/patch.log"; }
fi
head -2 "$STATE/patch.log" | sed 's/^/      /'

echo "==> deleting one machine leaves the other alone"
kubectl delete machine worker-a --wait=true --timeout=120s >/dev/null 2>&1
sleep 5
kubectl get node worker-a >/dev/null 2>&1 && check "worker-a node is gone" fail || check "worker-a node is gone" pass
[ "$(kubectl get node worker-b -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ] \
  && check "worker-b is still Ready" pass || check "worker-b is still Ready" fail

echo
[ "$failures" -eq 0 ] && echo "all checks passed" || echo "$failures check(s) failed"
exit "$failures"
