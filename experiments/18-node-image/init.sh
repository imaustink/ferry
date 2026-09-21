#!/bin/sh
# PID 1 on a ferry node.
#
# Everything it needs is on the kernel command line, because a VM booted by a
# controller has no other channel at first boot and a config drive is a second
# device to build and mount. The controller writes the address it allocated,
# the API server to join, and the token to join with; this brings the machine
# up and hands it to the kubelet.
set -u

# The kernel hands PID 1 an empty environment, so there is no PATH unless one is
# made. Everything here calls binaries by absolute path and did not notice --
# until the kubelet shelled out to `mount` for a projected volume and could not
# find it, leaving pods stuck in ContainerCreating with the reason three layers
# down in an event message.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

log() { echo "ferry-node: $*" > /dev/console; }
started=$(date +%s%N 2>/dev/null || echo 0)
elapsed() { echo $(( ($(date +%s%N) - started) / 1000000 )); }

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mkdir -p /dev/pts /dev/shm /run /tmp /sys/fs/cgroup
mount -t devpts devpts /dev/pts 2>/dev/null
mount -t tmpfs tmpfs /run
mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /dev/shm 2>/dev/null
mount -t cgroup2 cgroup2 /sys/fs/cgroup 2>/dev/null

# This is the whole point of being a machine rather than a container: /proc is
# ours and writable, so the kubelet's ContainerManager can set the kernel flags
# it insists on instead of refusing to start.
log "proc writable: $([ -w /proc/sys/vm/overcommit_memory ] && echo yes || echo no)"

# The size of the image this was cloned from, and there is no growing it: the
# ext4 is built without resize_inode. Worth logging, because it is the one
# number a Machine's spec.disk cannot change.
log "root filesystem $(df -h / | tail -1 | tr -s ' ' | cut -d' ' -f2)"

param() { # key
  sed -n "s/.*$1=\([^ ]*\).*/\1/p" /proc/cmdline
}
NODE_NAME=$(param ferry.node)
API_SERVER=$(param ferry.api)
TOKEN=$(param ferry.token)
ADDRESS=$(param ferry.address)      # CIDR, e.g. 192.168.66.5/24
GATEWAY=$(param ferry.gateway)
POD_CIDR=$(param ferry.podcidr)
DNS=$(param ferry.dns)
DNS_SERVICE=$(param ferry.dnssvc)
# Absent on a machine nobody tainted, and on any machine booted by a ferry-node
# older than the parameter -- in both cases the flag is simply not passed.
TAINTS=$(param ferry.taints)
CLUSTER_CIDR=$(param ferry.clustercidr)
# klog's level, so a burst can be watched at --v=4 -- where the kubelet logs
# each pod's phase boundaries and phases.py can read them -- without rebuilding
# this image to find out which phase stretched. Absent on a node booted by an
# older ferry-node, and the default is the 2 that was hardcoded here.
KUBELET_V=$(param ferry.kubeletv)

hostname "$NODE_NAME" 2>/dev/null
echo "$NODE_NAME" > /etc/hostname
# Written here rather than in the image: a Docker build bind-mounts /etc/hosts
# read-only, so it cannot be baked in. containerd copies this into every
# sandbox and refuses to start one without it.
printf '127.0.0.1 localhost\n::1 localhost\n127.0.1.1 %s\n' "$NODE_NAME" > /etc/hosts

# vmnet networks here have DHCP disabled -- the host allocates the address and
# tells the guest what it is, which is also how ferry addresses pods.
ip link set lo up
ip link set eth0 up
ip addr add "$ADDRESS" dev eth0
[ -n "$GATEWAY" ] && ip route add default via "$GATEWAY"
printf 'nameserver %s\n' "${DNS:-1.1.1.1}" > /etc/resolv.conf
log "address $ADDRESS via ${GATEWAY:-none} ($(elapsed)ms)"

log "binaries: $(ls -l /usr/local/bin/containerd 2>&1 | awk '{print $1, $5}') kubelet $(ls -l /usr/local/bin/kubelet 2>&1 | awk '{print $5}')"
log "starting containerd"
/usr/local/bin/containerd > /var/log/containerd.log 2>&1 &
containerd_pid=$!
n=0
# `ctr version` talks to the socket and will wait on it, so the readiness check
# is the socket appearing rather than a command that may not come back.
until [ -S /run/containerd/containerd.sock ]; do
  n=$((n + 1))
  if ! kill -0 "$containerd_pid" 2>/dev/null; then
    log "containerd exited"
    tail -5 /var/log/containerd.log > /dev/console 2>&1
    break
  fi
  [ "$n" -gt 600 ] && { log "containerd never opened its socket"; tail -5 /var/log/containerd.log > /dev/console 2>&1; break; }
  sleep 0.1
done
log "containerd ready ($(elapsed)ms)"

# The sandbox image, into the k8s.io namespace CRI reads from. Without it
# containerd pulls it from registry.k8s.io the first time a pod is scheduled,
# which puts a network round trip in front of the first pod on every node and
# leaves a node with no route to a registry unable to start one at all.
if [ -f /opt/ferry/sandbox-image.tar ]; then
  if /usr/local/bin/ctr -n k8s.io images import /opt/ferry/sandbox-image.tar \
       >/var/log/sandbox-image-import.log 2>&1; then
    log "sandbox image imported ($(elapsed)ms)"
  else
    # Not fatal -- containerd falls back to pulling. Said loudly because the
    # symptom otherwise is a slow first pod and nothing else, and with the
    # reason because the fallback is exactly what a node with no route to a
    # registry cannot do: the socket being up while the image service is not
    # yet serving, a truncated tar and a snapshotter error all look the same
    # from here and are fixed in different places.
    log "WARNING sandbox image import failed; containerd will pull it instead"
    tail -2 /var/log/sandbox-image-import.log > /dev/console 2>&1
  fi
fi

mkdir -p /etc/kubernetes /var/lib/kubelet
# vdb is this node's configuration: one read-only filesystem carrying what
# differs between machines. The certificate authority is too big for a kernel
# command line, and is the reason this disk exists at all.
mkdir -p /mnt/config
if mount -t ext4 -o ro /dev/vdb /mnt/config 2>/dev/null; then
  cp /mnt/config/ca.crt /etc/kubernetes/ca.crt
  log "config disk mounted, ca.crt $([ -s /etc/kubernetes/ca.crt ] && echo present || echo MISSING)"
else
  log "no config disk on /dev/vdb"
fi

cat > /etc/kubernetes/bootstrap-kubelet.conf <<EOF
apiVersion: v1
kind: Config
clusters:
- name: ferry
  cluster:
    server: $API_SERVER
    certificate-authority: /etc/kubernetes/ca.crt
contexts:
- name: bootstrap
  context: {cluster: ferry, user: bootstrap}
current-context: bootstrap
users:
- name: bootstrap
  user: {token: $TOKEN}
EOF

cat > /var/lib/kubelet/config.yaml <<EOF
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
authentication:
  anonymous: {enabled: false}
  webhook: {enabled: true}
  x509: {clientCAFile: /etc/kubernetes/ca.crt}
authorization: {mode: Webhook}
clusterDomain: cluster.local
${DNS_SERVICE:+clusterDNS: ["$DNS_SERVICE"]}
cgroupDriver: cgroupfs
failSwapOn: false
readOnlyPort: 0
# Sized to this machine's disk rather than to a Mac's. Asking for gigabytes
# free on a node whose root filesystem is a few gigabytes means DiskPressure
# from the first heartbeat, and everything scheduled here is evicted.
evictionHard:
  memory.available: "200Mi"
  nodefs.available: "500Mi"
  imagefs.available: "500Mi"
  nodefs.inodesFree: "5%"
EOF

# Taints belong on the kubelet rather than on a patch afterwards, and the
# reason is the window between the two. A node registers, becomes schedulable,
# and only then would a controller taint it; anything the scheduler placed in
# between is already running somewhere it was meant to be kept off. The
# provisioner's karpenter.sh/unregistered taint exists precisely to hold that
# window shut until it has finished syncing the node, so applying it late would
# be the same as not applying it.
#
# Built as a list so an empty TAINTS contributes no argument at all:
# --register-with-taints="" is rejected, and a kubelet that will not start is a
# worse failure than an untainted node.
set --
[ -n "$TAINTS" ] && set -- --register-with-taints="$TAINTS"
log "taints: ${TAINTS:-none}"

/usr/local/bin/kubelet \
  "$@" \
  --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf \
  --kubeconfig=/etc/kubernetes/kubelet.conf \
  --config=/var/lib/kubelet/config.yaml \
  --cert-dir=/var/lib/kubelet/pki \
  --hostname-override="$NODE_NAME" \
  --node-ip="${ADDRESS%%/*}" \
  --container-runtime-endpoint=unix:///run/containerd/containerd.sock \
  --v="${KUBELET_V:-2}" > /var/log/kubelet.log 2>&1 &
kubelet_pid=$!

# Stream the lines that matter to the console as they happen. Sampling the log
# every few seconds kept catching the startup flag dump and missing the reason
# the node was not joining.
(tail -f /var/log/kubelet.log 2>/dev/null \
  | grep --line-buffered -E '^[EW][0-9]|Successfully registered|Attempting to register' \
  > /dev/console) &

# Report early rather than after three minutes of silence: a node that cannot
# reach its cluster says so in the first seconds, and waiting out the timeout
# to find out is how an afternoon goes missing.
sleep 8
log "route: $(ip route show default 2>&1 | head -1)"
# Whether this is a network problem or an authentication one, said plainly.
# A kubelet blocked in TLS bootstrap logs nothing at all while it waits.
log "api /healthz: $(curl -sk -o /dev/null -w '%{http_code} in %{time_total}s' --max-time 8 "$API_SERVER/healthz" 2>&1)"
# klog marks errors with a leading E and warnings with W; the flag dump at
# startup contains the word "fail" and is not what is wanted here.
log "kubelet alive: $(kill -0 $kubelet_pid 2>/dev/null && echo yes || echo NO), log lines $(wc -l < /var/log/kubelet.log 2>/dev/null)"
# Everything except the flag dump, which is two hundred lines of noise that
# swallowed every attempt to sample this log.
log "--- kubelet, first lines that are not flags ---"
grep -v "FLAG:" /var/log/kubelet.log 2>/dev/null | head -25 > /dev/console
log "--- end ---"

# Routes to the other nodes' pods.
#
# Every machine is on one vmnet segment now, and each owns a slice of the pod
# network, so reaching a pod on another node is an ordinary route through that
# node's address. Nothing hands those out, so each node reads the Node list and
# keeps its own routing table in step -- which is what flannel's host-gw mode
# does, in a handful of lines, because the hard parts (one segment, a CIDR per
# node) are already true here.
#
# It authenticates with the kubelet's own certificate: system:node may list
# nodes, and a second credential would be a second thing to rotate.
route_agent() {
  cert=/var/lib/kubelet/pki/kubelet-client-current.pem
  while [ ! -f "$cert" ]; do sleep 1; done
  while true; do
    curl -s --cacert /etc/kubernetes/ca.crt --cert "$cert" --key "$cert" \
      "$API_SERVER/api/v1/nodes" 2>/dev/null \
      | jq -r '.items[] | select(.spec.podCIDR != null) |
               "\(.spec.podCIDR) \(.status.addresses[]
                  | select(.type=="InternalIP") | .address)"' \
      2>/dev/null | while read -r cidr via; do
        [ -z "$cidr" ] && continue
        [ "$cidr" = "$POD_CIDR" ] && continue
        [ "$via" = "${ADDRESS%%/*}" ] && continue
        # Only nodes on this machine's own segment. The Mac node advertises its
        # LAN address, which is routable from here -- through vmnet's NAT, as
        # the host -- so a route to its pods via that address looks reasonable
        # and silently blackholes: vmnet will not carry pod traffic between its
        # networks, which is the whole reason eth1 exists. Anything not on-link
        # here belongs to the switch, and the /16 on eth1 already covers it.
        case "$(ip -o route get "$via" 2>/dev/null)" in
          *" via "*) continue ;;
        esac
        case "$(ip route show "$cidr" 2>/dev/null)" in
          *"via $via"*) ;;
          *) ip route replace "$cidr" via "$via" 2>/dev/null && log "route $cidr via $via" ;;
        esac
      done
    sleep 10
  done
}
n=0
until grep -q "Successfully registered node" /var/log/kubelet.log 2>/dev/null; do
  n=$((n + 1))
  [ "$n" -gt 1800 ] && { log "kubelet never registered"; tail -20 /var/log/kubelet.log > /dev/console; break; }
  sleep 0.1
done
log "registered ($(elapsed)ms)"

# The pod network for this node's own pods, written now rather than at boot
# because the subnet is not this machine's to choose. kube-controller-manager
# allocates a slice per Node, and the routes other nodes install point at that
# slice -- so configuring the CNI from anything else produces pods with
# addresses nobody else can reach, which is exactly what happened the first
# time this ran.
cert=/var/lib/kubelet/pki/kubelet-client-current.pem
for _ in $(seq 1 120); do
  POD_CIDR=$(curl -s --cacert /etc/kubernetes/ca.crt --cert "$cert" --key "$cert" \
    "$API_SERVER/api/v1/nodes/$NODE_NAME" 2>/dev/null | jq -r '.spec.podCIDR // empty')
  [ -n "$POD_CIDR" ] && break
  sleep 1
done
log "pod cidr $POD_CIDR"

# eth1: ferry's pod network, the flat segment mode 1's pods are on.
#
# It cannot be configured at boot because the address depends on the slice
# kube-controller-manager hands this Node, and that is not known until after it
# registers. So it happens here, with the slice in hand.
#
# The same address as the bridge gateway, with the cluster prefix rather than
# the slice's -- the arrangement mode 1's own pods use (docs/POD-NETWORK.md,
# "Two interfaces, one address"). Longest match then does the routing for free:
# this machine's own pods are on the narrower /24 via cni0, and the rest of the
# cluster leaves by eth1.
#
# proxy_arp is what puts this machine's pods on that segment without giving each
# of them a port on it. A mode 1 pod treats the whole cluster CIDR as on-link
# and ARPs for whatever it wants to reach; with proxy_arp the machine answers
# for the addresses it routes to cni0, and forwards what arrives. Nothing on the
# mode 1 side needs a route, which matters because those pods are VMs nobody can
# reconfigure once they are running.
if [ -n "$POD_CIDR" ] && [ -n "$CLUSTER_CIDR" ] && ip link show eth1 >/dev/null 2>&1; then
  prefix=${CLUSTER_CIDR#*/}
  gw=$(echo "${POD_CIDR%/*}" | awk -F. '{print $1"."$2"."$3"."($4 + 1)}')
  ip link set eth1 up
  ip addr add "$gw/$prefix" dev eth1 2>/dev/null
  sysctl -w net.ipv4.conf.eth1.proxy_arp=1 >/dev/null 2>&1
  sysctl -w net.ipv4.conf.eth1.forwarding=1 >/dev/null 2>&1
  log "pod network: eth1 $gw/$prefix, proxy arp for $POD_CIDR"
else
  log "pod network: eth1 absent; mode 1 pods are unreachable from here"
fi

mkdir -p /etc/cni/net.d
cat > /etc/cni/net.d/10-ferry-node.conflist <<CNI
{
  "cniVersion": "1.0.0",
  "name": "ferry-node",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "cni0",
      "isGateway": true,
      "ipMasq": true,
      "ipam": {
        "type": "host-local",
        "ranges": [[{"subnet": "$POD_CIDR"}]],
        "routes": [{"dst": "0.0.0.0/0"}]
      }
    },
    {"type": "portmap", "capabilities": {"portMappings": true}}
  ]
}
CNI
log "cni configured ($(elapsed)ms)"

route_agent &
log "up"

# PID 1 may not exit: the kernel panics if it does.
while true; do sleep 3600; done
