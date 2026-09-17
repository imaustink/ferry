#!/usr/bin/env bash
# Milestone 3: pods on two machines reaching each other.
#
# Experiment 19 found why this could not work: a vmnet network belongs to the
# process that made it, so a process per machine put every node on a network of
# its own with no way across. ferry-node serve holds one network and hosts every
# machine on it; each machine owns a slice of the pod network; and each node
# keeps routes to the others from the Node list.
#
# What is checked is the thing that was impossible before: a pod on worker-a
# talking to a pod on worker-b.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
image_dir="$root/experiments/18-node-image"

STATE="${STATE:-${TMPDIR:-/tmp}/pod-network}"
API_PORT="${API_PORT:-18843}"
export KUBECONFIG="$STATE/admin.conf"
LAN_IP="${LAN_IP:-$(ipconfig getifaddr en0 2>/dev/null || echo 127.0.0.1)}"
KERNEL="${KERNEL:-$root/kernel/vmlinux-arm64}"
[ -f "$KERNEL" ] || KERNEL="$HOME/ferry/kernel/vmlinux-arm64"
DNS_SERVICE_IP=10.96.0.10
failures=0

check() { if [ "$2" = pass ]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); fi; }

serve_pid=""; machined_pid=""
cleanup() {
  [ -n "$machined_pid" ] && kill "$machined_pid" 2>/dev/null
  [ -n "$serve_pid" ] && kill "$serve_pid" 2>/dev/null
  sleep 1
  pkill -f "ferry-node serve --dir $STATE" 2>/dev/null
  [ "${KEEP:-0}" = 1 ] && return 0
  STATE="$STATE" "$root/control-plane/down.sh" >/dev/null 2>&1
}
trap cleanup EXIT

echo "==> control plane"
rm -rf "$STATE"; mkdir -p "$STATE/machines"
STATE="$STATE" PKI_DIR="$STATE/pki" NODE_NAME=cp-node ADVERTISE="$LAN_IP" \
  POD_GATEWAY="$LAN_IP" API_PORT="$API_PORT" \
  CONTROLLER_PORT=18857 SCHEDULER_PORT=18859 \
  ETCD_CLIENT_PORT=18979 ETCD_PEER_PORT=18980 \
  CLUSTER_CIDR=10.88.0.0/16 \
  "$root/control-plane/up.sh" >"$STATE/up.log" 2>&1 \
  || { echo "control plane failed"; tail -20 "$STATE/up.log"; exit 1; }
kubectl apply -f "$root/ferry-machined/crd.yaml" >/dev/null

render() {
  sed -e "s|__APISERVER_HOST__|$LAN_IP|g" -e "s|__APISERVER_PORT__|$API_PORT|g" \
      -e "s|__CLUSTER_CIDR__|10.88.0.0/16|g" \
      -e "s|__KUBE_PROXY_IMAGE__|registry.k8s.io/kube-proxy:v1.34.11|g" \
      -e "s|__COREDNS_IMAGE__|docker.io/coredns/coredns:1.11.3|g" \
      -e "s|__CLUSTER_DOMAIN__|cluster.local|g" -e "s|__UPSTREAM_DNS__|1.1.1.1|g" \
      -e "s|__DNS_SERVICE_IP__|$DNS_SERVICE_IP|g" "$1"
}
render "$image_dir/manifests/kube-proxy.yaml" | kubectl apply -f - >/dev/null
render "$image_dir/manifests/coredns.yaml" | kubectl apply -f - >/dev/null

echo "==> ferry-node serve (one network for every machine)"
"$image_dir/build/ferry-node" serve \
  --dir "$STATE/machines" \
  --kernel "$KERNEL" \
  --ca "$STATE/pki/ca.crt" \
  --api-server "https://$LAN_IP:$API_PORT" \
  --cluster-dns "$DNS_SERVICE_IP" \
  >"$STATE/serve.log" 2>&1 &
serve_pid=$!
sleep 3
grep -a "network" "$STATE/serve.log" | head -1 | sed 's/^/    /'

echo "==> ferry-machined"
"$root/bin/ferry-machined" \
  --kubeconfig "$KUBECONFIG" --kernel "$KERNEL" \
  --image "$image_dir/build/node.ext4" --state "$STATE" \
  --machines "$STATE/machines" \
  --api-server "https://$LAN_IP:$API_PORT" --ca "$STATE/pki/ca.crt" \
  --cluster-dns "$DNS_SERVICE_IP" \
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

for _ in $(seq 1 240); do
  [ "$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready')" -ge 2 ] && break
  sleep 2
done
kubectl get machines 2>&1 | head -4
[ "$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready')" -ge 2 ] \
  && check "both machines are Ready" pass || check "both machines are Ready" fail

# The point of the restructure: one network, so the two node addresses share a
# subnet instead of being on islands.
subnets=$(kubectl get machines -o jsonpath='{range .items[*]}{.status.address}{"\n"}{end}' 2>/dev/null \
  | awk -F. 'NF==4 {print $1"."$2"."$3}' | sort -u | grep -c .)
[ "$subnets" = 1 ] && check "both machines are on one network" pass || check "both machines are on one network" fail
echo "      addresses: $(kubectl get machines -o jsonpath='{range .items[*]}{.status.address}{" "}{end}' 2>/dev/null)"

echo "==> a pod on each machine"
kubectl delete pod ping pong --ignore-not-found >/dev/null 2>&1
kubectl run pong --image=public.ecr.aws/docker/library/alpine:3.20 --overrides='{"spec":{"nodeName":"worker-b"}}' \
  --restart=Never --command -- sh -c 'echo PONG > /tmp/i; httpd -f -p 8080 -h /tmp' >/dev/null 2>&1
for _ in $(seq 1 120); do
  [ "$(kubectl get pod pong -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ] && break
  sleep 2
done
pong_ip=$(kubectl get pod pong -o jsonpath='{.status.podIP}' 2>/dev/null)
[ -n "$pong_ip" ] && check "pod on worker-b has an address ($pong_ip)" pass || check "pod on worker-b has an address" fail

kubectl run ping --image=public.ecr.aws/docker/library/alpine:3.20 --overrides='{"spec":{"nodeName":"worker-a"}}' \
  --restart=Never --command -- sh -c "
    wget -qO- -T 10 http://$pong_ip:8080/i 2>/dev/null | grep -q PONG && echo CROSS_NODE_OK || echo CROSS_NODE_FAIL
    sleep 300" >/dev/null 2>&1
for _ in $(seq 1 120); do
  case "$(kubectl get pod ping -o jsonpath='{.status.phase}' 2>/dev/null)" in Running|Succeeded) break ;; esac
  sleep 2
done
sleep 12
logs=$(kubectl logs ping 2>/dev/null)
echo "      ping says: ${logs:-<nothing>}"
printf '%s' "$logs" | grep -q CROSS_NODE_OK \
  && check "a pod on worker-a reaches a pod on worker-b" pass \
  || check "a pod on worker-a reaches a pod on worker-b" fail

echo "      routes seen by the nodes:"
grep -a "route " "$STATE/serve.log" | tail -4 | sed 's/^/        /'

echo
[ "$failures" -eq 0 ] && echo "all checks passed" || echo "$failures check(s) failed"
[ "${KEEP:-0}" = 1 ] && { echo "left running: export KUBECONFIG=$KUBECONFIG"; wait $machined_pid; }
exit "$failures"
