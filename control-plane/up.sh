#!/usr/bin/env bash
# Starts a Kubernetes control plane as four native macOS processes. No VM, no
# kubelet, no static pods -- this is the piece that kubeadm cannot install,
# because kubeadm's only delivery mechanism is static pods run by a kubelet on
# the control plane host, and there is no kubelet on macOS.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
FERRY_ROOT="$(cd "$here/.." && pwd)"
export FERRY_ROOT
# shellcheck source=../lib/versions.sh
. "$FERRY_ROOT/lib/versions.sh"

# Which Kubernetes this control plane is. The caller decides -- 'ferry up' says
# what the checkout is built at, 'ferry upgrade' says what it is moving to --
# and everything below runs out of that version's directory rather than out of
# bin/. Running the version by name is what makes an upgrade a restart: the
# binaries that come up are the ones asked for, not whatever bin/ points at.
K8S_VERSION="${K8S_VERSION:-$FERRY_DEFAULT_K8S_VERSION}"
bin="$(ferry_version_dir "$K8S_VERSION")"
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
K8S_VERSION="$K8S_VERSION" "$here/fetch-binaries.sh" >/dev/null

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

# The pid a component is running as now, if it is running at all.
running_pid() { # name
  local pid
  pid="$(cat "$STATE/$1.pid" 2>/dev/null)" || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && echo "$pid"
}

# SIGTERM, ten seconds of patience, then SIGKILL -- down.sh's contract.
stop_pid() { # name pid
  kill -TERM "$2" 2>/dev/null || return 0
  local i=0
  while [ "$i" -lt 200 ] && kill -0 "$2" 2>/dev/null; do sleep 0.05; i=$((i + 1)); done
  if kill -0 "$2" 2>/dev/null; then
    kill -KILL "$2" 2>/dev/null
    echo "    - $1 (pid $2, forced)"
  else
    echo "    - $1 (pid $2)"
  fi
}

# Anything already running is being replaced, which is what an upgrade is. A
# plain 'ferry up' finds nothing running and starts everything.
#
#   FERRY_KEEP_ETCD=1   leave a running etcd alone. The caller sets it when the
#                       version being started pairs with the etcd that is
#                       running: restarting it would add its own startup to the
#                       outage and take the API server down with it.
#   FERRY_HANDOVER=1    replace a running API server without refusing a
#                       connection, holding its port with the bridge at
#   FERRY_HANDOVER_BIN  while one hands over to the other. See below.

echo "==> starting control plane (advertise=$ADVERTISE)"

# etcd's durability barrier, which on macOS is not the same bargain it is on
# Linux.
#
# Measured on a 20-pod burst: ferry's etcd averages 5.13ms per WAL fsync and
# 10.26ms per backend commit, against kind's 0.88ms and 1.78ms. kind's etcd is
# not better tuned -- it is inside Docker Desktop's VM, where the guest's
# fsync reaches a virtual disk whose host-side durability Docker has already
# relaxed. ferry's runs natively and pays a real APFS barrier for every write.
#
# Every pod status update is an etcd write, and the kubelet's status manager
# issues them from one goroutine, so those milliseconds are serial and land on
# the critical path of a burst: phase=Running to status stored is 188ms median
# on ferry against kind's 8ms.
#
# Off by default. This is the cluster's data, and a Mac that loses power
# mid-write can leave it needing a restore -- not something to impose on
# anyone who has not asked. FERRY_ETCD_NO_FSYNC=1 opts in, and for a cluster
# that is recreated on demand it is close to free.
# Spelled ${a[@]+"${a[@]}"} below: under `set -u` bash 3.2, which is the bash
# macOS ships, expanding an empty array as "${a[@]}" is an unbound variable
# and the control plane would not start at all when the flag is off.
etcd_fsync_args=()
if [ -n "${FERRY_ETCD_NO_FSYNC:-}" ]; then
  etcd_fsync_args+=(--unsafe-no-fsync)
  echo "    ! etcd --unsafe-no-fsync (FERRY_ETCD_NO_FSYNC)"
fi

if [ -n "${FERRY_KEEP_ETCD:-}" ] && pid="$(running_pid etcd)" \
   && "$bin/etcdctl" --endpoints=127.0.0.1:$ETCD_CLIENT_PORT endpoint health >/dev/null 2>&1; then
  echo "    = etcd (pid $pid, kept)"
else
  if pid="$(running_pid etcd)"; then stop_pid etcd "$pid"; fi
  start etcd "$bin/etcd" \
    --data-dir="$STATE/etcd" \
    ${etcd_fsync_args[@]+"${etcd_fsync_args[@]}"} \
    --listen-client-urls=http://127.0.0.1:$ETCD_CLIENT_PORT \
    --advertise-client-urls=http://127.0.0.1:$ETCD_CLIENT_PORT \
    --listen-peer-urls=http://127.0.0.1:$ETCD_PEER_PORT \
    --initial-advertise-peer-urls=http://127.0.0.1:$ETCD_PEER_PORT \
    --initial-cluster=default=http://127.0.0.1:$ETCD_PEER_PORT
fi

# 0.1s, not 1s, and the same thirty seconds of patience. etcd answers in about
# a fifth of a second; at one-second granularity that cost a whole one, and
# the same was true of both API server checks below. Three rounded-up waits
# were most of the 4.6s this script contributed to `ferry up`.
for i in $(seq 1 300); do
  "$bin/etcdctl" --endpoints=127.0.0.1:$ETCD_CLIENT_PORT endpoint health >/dev/null 2>&1 && break
  sleep 0.1
done

# An array, because a handover starts it at a different point from a plain
# start. The comments inside it expand to nothing, as they did as arguments.
# shellcheck disable=SC2054,SC2206,SC2207
api_cmd=("$bin/kube-apiserver" \
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
  --service-node-port-range="${SERVICE_NODE_PORT_RANGE:-30000-32767}" \
  `# End watches when told to stop, rather than waiting on them. Without this` \
  `# the HTTP server's shutdown waits the full 60s request timeout for the` \
  `# kubelet's, ferry-proxyd's and every controller's watch streams to end on` \
  `# their own, which they never do -- so SIGTERM took 60.2s, measured, and` \
  `# down.sh killed it at ten. Ended watches are re-established by the client` \
  `# from the resourceVersion it had, which is what they are built to do.` \
  --shutdown-watch-termination-grace-period="${FERRY_WATCH_GRACE:-2s}" \
  `# The kubernetes Service's endpoint is written below rather than kept by` \
  `# the API server. Its reconciler takes the address out as the API server` \
  `# stops, which with one API server at one address empties the Service for` \
  `# every in-cluster client until the next one puts it back -- a refused` \
  `# connection to 10.96.0.1 on every restart and every upgrade.` \
  --endpoint-reconciler-type=none)

api_readyz() { # host
  curl -sgk --max-time 1 --cert "$PKI_DIR/admin.crt" --key "$PKI_DIR/admin.key" \
    "https://$1:$API_PORT/readyz" 2>/dev/null | grep -qx ok
}
# kubectl as admin, normally through 127.0.0.1. During a handover kubectl_at
# points it at [::1] instead, which reaches the new API server directly rather
# than waiting in the bridge behind everyone else.
kubectl_at=()
kube() { kubectl --kubeconfig "$STATE/admin.conf" ${kubectl_at[@]+"${kubectl_at[@]}"} "$@"; }
# The kubernetes Service's one endpoint: this API server, at the address it
# advertises. Written by ferry because the API server's own reconciler is off
# (see --endpoint-reconciler-type above), and written whole, both the Endpoints
# and the EndpointSlice kube-proxy reads, so a fresh cluster gets them too. The
# first upgrade from an API server that still ran the reconciler finds them
# emptied by its departure, and this puts them back.
write_kubernetes_endpoint() {
  kube apply --server-side --force-conflicts --field-manager=ferry --validate=false -f - >/dev/null 2>&1 <<YAML
apiVersion: v1
kind: Endpoints
metadata:
  name: kubernetes
  namespace: default
  labels: {endpointslice.kubernetes.io/skip-mirror: "true"}
subsets:
- addresses: [{ip: $ADVERTISE}]
  ports: [{name: https, port: $API_PORT, protocol: TCP}]
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: kubernetes
  namespace: default
  labels: {kubernetes.io/service-name: kubernetes}
addressType: IPv4
endpoints:
- addresses: [$ADVERTISE]
  conditions: {ready: true}
ports: [{name: https, port: $API_PORT, protocol: TCP}]
YAML
}
listening() { # host -- is anything accepting on the API port there
  nc -z -G 1 "$1" "$API_PORT" >/dev/null 2>&1
}

# Replacing a running API server.
#
# The obvious way is stop, then start, and every client is refused from the one
# to the other: 1.9s for a pooled client and 2.9s before /readyz answers, on
# this Mac with etcd left running.
#
# Two API servers cannot overlap on macOS. The port can be shared with
# SO_REUSEPORT, but macOS does not balance a shared port -- every connection
# goes to whichever listener bound *first* -- and an API server has to reach
# itself during its own start: its post-start hooks run through a loopback
# client that dials [::1]:port with a certificate it generated a moment before.
# Beside the old one, those dials reach the old one and fail verification, and
# the node port repair hook does not try again for three minutes, which is two
# after the process has given up and exited. Measured, both halves, in
# experiments/28-control-plane-upgrades.
#
# So they do not overlap; the port is held instead. ferry-handover binds every
# IPv4 address on this port -- a more specific listener than the API server's
# wildcard, which macOS always prefers, and a different address family, so it
# binds beside one started with no socket options at all -- and splices what
# arrives through to [::1], retrying while nothing is there. Every client
# arrives over IPv4, so nothing is refused; a connection made during the switch
# waits. [::1] stays the API server's own, which is what its loopback client
# needs. Once the new one is ready the bridge lets go, and new connections go
# straight to it again.
#
# Without the bridge built, this is stop then start.
old_api=""
if pid="$(running_pid kube-apiserver)"; then
  if [ -n "${FERRY_HANDOVER:-}" ] && [ -x "${FERRY_HANDOVER_BIN:-}" ]; then
    old_api="$pid"
  else
    stop_pid kube-apiserver "$pid"
  fi
fi

if [ -n "$old_api" ]; then
  "$FERRY_HANDOVER_BIN" --port "$API_PORT" >"$STATE/logs/handover.log" 2>&1 &
  bridge=$!
  for i in $(seq 1 100); do
    grep -q '^bridging' "$STATE/logs/handover.log" 2>/dev/null && break
    kill -0 "$bridge" 2>/dev/null || break
    sleep 0.02
  done
  if ! grep -q '^bridging' "$STATE/logs/handover.log" 2>/dev/null; then
    kill "$bridge" 2>/dev/null || true
    echo "    ! the bridge did not start ($(tail -1 "$STATE/logs/handover.log")); stopping first instead"
    stop_pid kube-apiserver "$old_api"
    old_api=""
  else
    echo "    . $(head -1 "$STATE/logs/handover.log")"
  fi
fi

if [ -n "$old_api" ]; then
  # Hold first, so nothing that arrives from here on reaches the new one before
  # it is ready.
  kill -USR1 "$bridge" 2>/dev/null || true
  kill -TERM "$old_api" 2>/dev/null || true
  # Its listener goes a few milliseconds after the signal, once it has taken
  # itself out of the kubernetes Service; the drain of what it was already
  # serving carries on regardless. The new one must not bind before then, or
  # it is the one that cannot reach itself.
  for i in $(seq 1 500); do listening ::1 || break; sleep 0.01; done
  # The old process keeps its descriptor, so its last lines land here rather
  # than interleaved into the new one's log.
  [ -f "$STATE/logs/kube-apiserver.log" ] \
    && mv "$STATE/logs/kube-apiserver.log" "$STATE/logs/kube-apiserver.previous.log"
  start kube-apiserver "${api_cmd[@]}"
  new_api="$(cat "$STATE/kube-apiserver.pid")"
  kubectl_at=(--server "https://[::1]:$API_PORT" --tls-server-name localhost)
  # An old API server that still ran the endpoint reconciler has just emptied
  # the Service. Put it back the moment the new one takes a write.
  ( for i in $(seq 1 300); do write_kubernetes_endpoint && break; sleep 0.05; done ) &
  restoring=$!
  for i in $(seq 1 600); do
    api_readyz "[::1]" && break
    kill -0 "$new_api" 2>/dev/null || break
    sleep 0.05
  done
  wait "$restoring" 2>/dev/null || true
  if api_readyz "[::1]"; then
    echo "    - kube-apiserver (pid $old_api, handed over)"
  else
    echo "    !! the new API server did not become ready" >&2
    tail -15 "$STATE/logs/kube-apiserver.log" | sed 's/^/       /' >&2
  fi
  # Let go. New connections reach the API server directly again; the ones the
  # bridge spliced are closed as each falls quiet, and their clients reconnect.
  kill -TERM "$bridge" 2>/dev/null || true
  kubectl_at=()
  i=0
  while [ "$i" -lt 300 ] && kill -0 "$old_api" 2>/dev/null; do sleep 0.05; i=$((i + 1)); done
  kill -KILL "$old_api" 2>/dev/null || true
  kill -0 "$new_api" 2>/dev/null || { echo "    !! the new API server exited" >&2; exit 1; }
else
  start kube-apiserver "${api_cmd[@]}"
fi

echo "    . waiting for /livez"
for i in $(seq 1 600); do
  curl -sk --cert "$PKI_DIR/admin.crt" --key "$PKI_DIR/admin.key" \
    https://127.0.0.1:$API_PORT/livez 2>/dev/null | grep -q ok && break
  sleep 0.1
done

# These two stop before their replacements start, never beside them: both run
# with --leader-elect=false, so two of either would each act on the cluster as
# if it were the only one. Neither serves the API, so the gap between them is
# a pause in reconciling rather than an outage.
for name in kube-controller-manager kube-scheduler; do
  if pid="$(running_pid "$name")"; then stop_pid "$name" "$pid"; fi
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
for i in $(seq 1 600); do
  [ "$(kubectl get --raw /healthz 2>/dev/null)" = "ok" ] && break
  sleep 0.1
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

# Every start, not only the first: the address it advertises follows the Mac's
# network, and nothing else writes it any more.
write_kubernetes_endpoint || echo "    ! could not write the kubernetes Service's endpoint" >&2

# Write down what this cluster now is.
#
# The store records what a checkout has built; this records what is running.
# They are different facts -- a build moves one and leaves the other where it
# was until something restarts -- and an upgrade needs a "from", which before
# this nothing anywhere recorded.
FERRY_HOME="$STATE" ferry_write_cluster_version \
  "$K8S_VERSION" "$(ferry_control_plane_version "$K8S_VERSION")" \
  "$(ferry_etcd_version "$K8S_VERSION")"

echo "==> control plane up"
echo "    export KUBECONFIG=$STATE/admin.conf"
kubectl get --raw /healthz; echo
kubectl get ns
