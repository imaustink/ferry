#!/usr/bin/env bash
# Drives an unmodified upstream CNI plugin inside a pod's virtual machine.
#
# This is the half the first pass could not test. portmap is Linux-only -- it
# wants netlink and netfilter -- so it cannot run on the Mac at all. It runs
# where those things exist: inside the pod, against the pod's own root netns,
# which is what the hypervisor created in place of a main plugin's netns.
#
# hostPort is the feature that makes it visible. ferry never implemented it,
# upstream already had, and the whole of ferry's side is a listener.
#
# Needs a running cluster: ferry up
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
run="${FERRY_RUN:-/tmp/ferry-run}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.ferry/admin.conf}"
port="${PORT:-18080}"

command -v kubectl >/dev/null || { echo "kubectl is required" >&2; exit 1; }
kubectl get nodes >/dev/null 2>&1 || { echo "no cluster; run: ferry up" >&2; exit 1; }

cleanup() { kubectl delete pod hostport-demo --ignore-not-found --wait=false >/dev/null 2>&1; }
trap cleanup EXIT

echo "==> a pod that asks for a hostPort"
kubectl delete pod hostport-demo --ignore-not-found --wait=true >/dev/null 2>&1
kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: hostport-demo
spec:
  containers:
  - name: web
    image: docker.io/library/busybox:1.36
    command: ["sh", "-c", "echo 'hello from a pod VM' > /tmp/index.html && httpd -f -h /tmp -p 80"]
    ports:
    - containerPort: 80
      hostPort: $port
      protocol: TCP
YAML
kubectl wait --for=condition=Ready pod/hostport-demo --timeout=180s >/dev/null || {
  kubectl describe pod hostport-demo | tail -20; exit 1; }

pod="$(kubectl get pod hostport-demo -o jsonpath='{.status.podIP}')"
container="$(kubectl get pod hostport-demo -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's|.*://||')"
echo "    pod ip     $pod   -- and the Mac is on that network, so it dials it directly"

# The plugin needs NET_ADMIN to program a kernel, so reading its work does too.
# ferry-cri's exec socket is what ferry-cni itself dials; this speaks the same
# framing, which is the point -- nothing here is a special case.
echo
echo "==> what portmap wrote, in the pod's own kernel"
python3 "$here/podexec.py" "${FERRY_EXEC_SOCK:-/tmp/ferry-exec.sock}" "$container" \
  /.ferry/nft list chain ip cni_hostport hostports 2>&1 | sed 's/^/    /'

echo "==> ferry-cri's note to the host edge"
sed 's/^/    /' "$run/cri/hostports"

# ferry-proxy learns about a hostPort by polling the file above, so the host
# edge appears a moment after the pod does. Waiting for it is the difference
# between testing the feature and testing the poll interval.
fetch() {
  local url="$1" body=""
  for _ in $(seq 1 20); do
    body="$(curl -s --max-time 5 "$url")" && [ -n "$body" ] && { echo "$body"; return 0; }
    sleep 1
  done
  echo "(no answer)"
}

echo
echo "==> reaching it"
printf "    %-22s %s\n" "$pod:$port" "$(fetch "http://$pod:$port/")"
echo "      the pod's own address -- portmap alone, no host involvement"
printf "    %-22s %s\n" "127.0.0.1:$port" "$(fetch "http://127.0.0.1:$port/")"
echo "      the node -- which is this Mac, so ferry-proxy carries the last hop"

echo
echo "==> teardown unwinds the chain"
kubectl delete pod hostport-demo --wait=true >/dev/null
sleep 4
printf "    %-22s %s\n" "hostports file" "$( [ -s "$run/cri/hostports" ] && cat "$run/cri/hostports" || echo '(empty)')"
printf "    %-22s %s\n" "127.0.0.1:$port" "$(curl -s --max-time 4 "http://127.0.0.1:$port/" || echo '(closed)')"
