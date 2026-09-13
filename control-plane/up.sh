#!/usr/bin/env bash
# Starts a Kubernetes control plane as four native macOS processes. No VM, no
# kubelet, no static pods -- this is the piece that kubeadm cannot install,
# because kubeadm's only delivery mechanism is static pods run by a kubelet on
# the control plane host, and there is no kubelet on macOS.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
bin="$here/../bin"
STATE="${STATE:-/tmp/ferry}"
PKI_DIR="${PKI_DIR:-$STATE/pki}"
NODE_NAME="${NODE_NAME:-ferry-mac}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/16}"
CLUSTER_CIDR="${CLUSTER_CIDR:-10.244.0.0/16}"

# The endpoint reconciler writes this address into the kubernetes Endpoints
# object, which every in-cluster client resolves 10.96.0.1 to. It may not be
# loopback, and it must be reachable from inside a pod -- every pod, on every
# machine in the cluster.
#
# That last part rules out the vmnet gateway, which was the obvious choice while
# ferry was one Mac: a gateway belongs to one Mac's vmnet network, and pods on
# another Mac cannot reach it, so the kubernetes Service works for local pods and
# fails everywhere else. The LAN address is reachable from both -- pods get to it
# through their own vmnet NAT -- so ferry advertises that and falls back to the
# gateway only when there is no network to speak of.
#
# The cost is that the advertised address changes when the Mac changes networks,
# and the kubernetes Service keeps the old one until the control plane restarts.
# kubeadm has the same property for the same reason.
POD_GATEWAY="${POD_GATEWAY:-192.168.66.1}"
ADVERTISE="${ADVERTISE:-$POD_GATEWAY}"
if [ -z "$ADVERTISE" ]; then
  echo "no non-loopback address found; set ADVERTISE=" >&2; exit 1
fi

# Ports are the caller's to choose. ferry shifts them per profile so a second
# checkout can run its own cluster without fighting this one for a socket.
API_PORT="${API_PORT:-6443}"
# The controller manager and scheduler serve their own health and metrics ports.
# They are easy to forget, because nothing talks to them and a clash shows up
# only as a component that will not start.
CONTROLLER_PORT="${CONTROLLER_PORT:-10257}"
SCHEDULER_PORT="${SCHEDULER_PORT:-10259}"
ETCD_CLIENT_PORT="${ETCD_CLIENT_PORT:-2379}"
ETCD_PEER_PORT="${ETCD_PEER_PORT:-2380}"

mkdir -p "$STATE/logs" "$STATE/etcd"
PKI_DIR="$PKI_DIR" NODE_NAME="$NODE_NAME" VMNET_GW="$POD_GATEWAY" "$here/pki.sh"
"$here/fetch-binaries.sh" >/dev/null

kubeconfig() { # name certbase
  cat > "$STATE/$1.conf" <<YAML
apiVersion: v1
kind: Config
clusters:
- name: ferry
  cluster:
    server: https://127.0.0.1:$API_PORT
    certificate-authority: $PKI_DIR/ca.crt
contexts:
- name: ferry
  context: {cluster: ferry, user: $1}
current-context: ferry
users:
- name: $1
  user:
    client-certificate: $PKI_DIR/$2.crt
    client-key: $PKI_DIR/$2.key
YAML
}
kubeconfig admin              admin
kubeconfig controller-manager controller-manager
kubeconfig scheduler          scheduler
kubeconfig kubelet            kubelet

start() { # name cmd...
  local name=$1; shift
  "$@" >"$STATE/logs/$name.log" 2>&1 &
  echo $! > "$STATE/$name.pid"
  echo "    + $name (pid $!)"
}

echo "==> starting control plane (advertise=$ADVERTISE)"

start etcd "$bin/etcd" \
  --data-dir="$STATE/etcd" \
  --listen-client-urls=http://127.0.0.1:$ETCD_CLIENT_PORT \
  --advertise-client-urls=http://127.0.0.1:$ETCD_CLIENT_PORT \
  --listen-peer-urls=http://127.0.0.1:$ETCD_PEER_PORT \
  --initial-advertise-peer-urls=http://127.0.0.1:$ETCD_PEER_PORT \
  --initial-cluster=default=http://127.0.0.1:$ETCD_PEER_PORT

for i in $(seq 1 30); do
  "$bin/etcdctl" --endpoints=127.0.0.1:$ETCD_CLIENT_PORT endpoint health >/dev/null 2>&1 && break
  sleep 1
done

start kube-apiserver "$bin/kube-apiserver" \
  --etcd-servers=http://127.0.0.1:$ETCD_CLIENT_PORT \
  --secure-port=$API_PORT --bind-address=0.0.0.0 --advertise-address="$ADVERTISE" \
  --service-cluster-ip-range="$SERVICE_CIDR" \
  --tls-cert-file="$PKI_DIR/apiserver.crt" --tls-private-key-file="$PKI_DIR/apiserver.key" \
  --client-ca-file="$PKI_DIR/ca.crt" \
  --kubelet-client-certificate="$PKI_DIR/apiserver-kubelet-client.crt" \
  --kubelet-client-key="$PKI_DIR/apiserver-kubelet-client.key" \
  --kubelet-preferred-address-types=InternalIP,Hostname \
  --service-account-key-file="$PKI_DIR/sa.pub" \
  --service-account-signing-key-file="$PKI_DIR/sa.key" \
  --service-account-issuer=https://kubernetes.default.svc.cluster.local \
  --requestheader-client-ca-file="$PKI_DIR/front-proxy-ca.crt" \
  --requestheader-allowed-names=front-proxy-client \
  --requestheader-extra-headers-prefix=X-Remote-Extra- \
  --requestheader-group-headers=X-Remote-Group \
  --requestheader-username-headers=X-Remote-User \
  --proxy-client-cert-file="$PKI_DIR/front-proxy-client.crt" \
  --proxy-client-key-file="$PKI_DIR/front-proxy-client.key" \
  --authorization-mode=Node,RBAC --allow-privileged=true \
  `# A node on another Mac has no credentials yet, so it authenticates with a` \
  `# bootstrap token to ask for a certificate. Without this the token is not a` \
  `# credential at all and the join fails as Unauthorized.` \
  --enable-bootstrap-token-auth=true \
  `# An aggregated API -- metrics.k8s.io and anything else served by a pod -- is` \
  `# answered by that pod, and the API server has to reach it to ask. Routing to` \
  `# the endpoint rather than the Service means it dials a pod address, which is` \
  `# on this node's vmnet subnet and so reachable from the Mac.` \
  --enable-aggregator-routing=true \
  `# Node ports are bound on the Mac, so two profiles need separate ranges.` \
  --service-node-port-range="${SERVICE_NODE_PORT_RANGE:-30000-32767}"

echo "    . waiting for /livez"
for i in $(seq 1 60); do
  curl -sk --cert "$PKI_DIR/admin.crt" --key "$PKI_DIR/admin.key" \
    https://127.0.0.1:6443/livez 2>/dev/null | grep -q ok && break
  sleep 1
done

start kube-controller-manager "$bin/kube-controller-manager" \
  --kubeconfig="$STATE/controller-manager.conf" \
  --authentication-kubeconfig="$STATE/controller-manager.conf" \
  --authorization-kubeconfig="$STATE/controller-manager.conf" \
  --service-account-private-key-file="$PKI_DIR/sa.key" \
  --root-ca-file="$PKI_DIR/ca.crt" \
  --cluster-signing-cert-file="$PKI_DIR/ca.crt" \
  --cluster-signing-key-file="$PKI_DIR/ca.key" \
  --requestheader-client-ca-file="$PKI_DIR/front-proxy-ca.crt" \
  --use-service-account-credentials=true --leader-elect=false \
  --bind-address=127.0.0.1 --secure-port=$CONTROLLER_PORT \
  --allocate-node-cidrs=true --cluster-cidr="$CLUSTER_CIDR" \
  --service-cluster-ip-range="$SERVICE_CIDR" \
  --controllers='*,bootstrap-signer-controller,token-cleaner-controller'

start kube-scheduler "$bin/kube-scheduler" \
  --kubeconfig="$STATE/scheduler.conf" \
  --authentication-kubeconfig="$STATE/scheduler.conf" \
  --authorization-kubeconfig="$STATE/scheduler.conf" \
  --requestheader-client-ca-file="$PKI_DIR/front-proxy-ca.crt" \
  --leader-elect=false --bind-address=127.0.0.1 --secure-port=$SCHEDULER_PORT

export KUBECONFIG="$STATE/admin.conf"
# /livez only reports that the process is serving. The RBAC and priority-class
# bootstrap hooks run after that, and applying manifests before they finish
# fails, so wait on /healthz which covers them.
echo "    . waiting for /healthz"
for i in $(seq 1 60); do
  [ "$(kubectl get --raw /healthz 2>/dev/null)" = "ok" ] && break
  sleep 1
done

# The Node authorizer covers a kubelet's access to objects tied to its own
# pods, but the kubelet still needs the baseline system:node role.
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ferry:system-nodes
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:node
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: system:nodes
YAML

echo "==> control plane up"
echo "    export KUBECONFIG=$STATE/admin.conf"
kubectl get --raw /healthz; echo
kubectl get ns
