#!/usr/bin/env bash
# A Kubernetes node, inside one VM.
#
# This is mode 2's milestone 1: not a pod that is a machine, but a machine that
# is a node -- containerd, a CNI, and a kubelet that bootstraps against the
# control plane running natively on the Mac. Pods scheduled here are ordinary
# Linux containers sharing this kernel.
#
# Everything is reported as KEY=VALUE on stdout, because the host reads results
# out of the console rather than by connecting to anything.
#
# Passed in by the runner:
#   NODE_NAME        what to register as
#   API_SERVER       https://host:port the kubelet bootstraps against
#   BOOTSTRAP_TOKEN  id.secret, already created in the cluster
#   CA_HASH          sha256:... the cluster CA must match
#   CLUSTER_DNS      address of the cluster's DNS service
set -u

STAGE=/opt/node
export PATH=/usr/local/bin:$PATH

started=$(date +%s%N)
elapsed() { echo $(( ($(date +%s%N) - started) / 1000000 )); }

tar xzf "$STAGE/containerd.tar.gz" -C /usr/local || { echo SETUP_FAIL=containerd; sleep 900; }
cp "$STAGE/runc" /usr/local/bin/runc
cp "$STAGE/kubelet" /usr/local/bin/kubelet
chmod +x /usr/local/bin/runc /usr/local/bin/kubelet
mkdir -p /opt/cni/bin && tar xzf "$STAGE/cni-plugins.tgz" -C /opt/cni/bin
mkdir -p /etc/ssl/certs && cp "$STAGE/ca-certificates.crt" /etc/ssl/certs/ca-certificates.crt
echo UNPACKED_MS=$(elapsed)

# cgroup v2 arrives with every controller available and none delegated, and
# cgroup v2 forbids a cgroup from holding both processes and enabled
# controllers -- so the processes move to a leaf before the controllers go down
# to children. Without this runc cannot make a cgroup for a container.
mkdir -p /sys/fs/cgroup/init
for p in $(cat /sys/fs/cgroup/cgroup.procs 2>/dev/null); do
  echo "$p" >/sys/fs/cgroup/init/cgroup.procs 2>/dev/null
done
echo "+cpu +cpuset +io +memory +pids" >/sys/fs/cgroup/cgroup.subtree_control 2>/dev/null

# The kubelet's ContainerManager sets vm/overcommit_memory, kernel/panic and
# kernel/panic_on_oops at startup and refuses to run if it cannot -- reasonably,
# since a node that panics rather than corrupting is part of the bargain. A
# container gets /proc/sys read-only, so this is the first place the difference
# between "a container" and "a machine" actually bites: a node image would boot
# with a writable /proc and never meet this.
mount -o remount,rw /proc/sys 2>/dev/null || mount -t proc proc /proc 2>/dev/null
echo PROCSYS_WRITABLE=$([ -w /proc/sys/vm/overcommit_memory ] && echo 1 || echo 0)

# A pod network for this node's own pods. The bridge is local to the VM, which
# is enough to make the node Ready and to run pods; routing between node VMs is
# milestone 3.
mkdir -p /etc/cni/net.d
#
# No ipMasq and no portmap, because both reach for iptables and the base image
# has none -- the bridge plugin fails the sandbox outright without it. A node
# image has to carry iptables (or nftables and the legacy shim); ferry already
# ships nft into pods for exactly this reason. Until then pods talk on the
# bridge and to the node, which is what this milestone is proving.
cat >/etc/cni/net.d/10-ferry-node.conflist <<'CNI'
{
  "cniVersion": "1.0.0",
  "name": "ferry-node",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "cni0",
      "isGateway": true,
      "ipMasq": false,
      "ipam": {"type": "host-local", "ranges": [[{"subnet": "10.88.0.0/16"}]], "routes": [{"dst": "0.0.0.0/0"}]}
    }
  ]
}
CNI

# containerd builds each sandbox's hosts file from the node's own, and refuses
# to start a sandbox when there is nothing to copy. A machine has these; a
# container image need not, and this one does not.
[ -f /etc/hosts ] || printf '127.0.0.1 localhost\n::1 localhost\n' >/etc/hosts
[ -f /etc/resolv.conf ] || printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' >/etc/resolv.conf

containerd >/var/log/containerd.log 2>&1 &
n=0
until ctr version >/dev/null 2>&1; do
  n=$((n + 1))
  [ "$n" -gt 300 ] && { echo SETUP_FAIL=containerd_never_ready; tail -5 /var/log/containerd.log; sleep 900; }
  sleep 0.1
done
echo CONTAINERD_READY_MS=$(elapsed)

# The kubelet asks for its own certificate rather than being handed one. The
# token authenticates that request and nothing else; the CA hash is how the
# node decides the server answering is the cluster it meant to join.
mkdir -p /etc/kubernetes /var/lib/kubelet
cat >/etc/kubernetes/bootstrap-kubelet.conf <<EOF
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
  user:
    token: $BOOTSTRAP_TOKEN
EOF
cp "$STAGE/ca.crt" /etc/kubernetes/ca.crt

cat >/var/lib/kubelet/config.yaml <<EOF
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
authentication:
  anonymous: {enabled: false}
  webhook: {enabled: true}
  x509: {clientCAFile: /etc/kubernetes/ca.crt}
authorization: {mode: Webhook}
clusterDomain: cluster.local
${CLUSTER_DNS:+clusterDNS: [$CLUSTER_DNS]}
cgroupDriver: cgroupfs
failSwapOn: false
readOnlyPort: 0
# Sized to this node's disk, which is the VM's root filesystem and measured in
# gigabytes rather than tens of them. ferry's own thresholds are 4Gi/2Gi for a
# Mac's disk; asking for 2Gi free on a 2.2Gi filesystem means the node reports
# DiskPressure the moment it starts and evicts everything scheduled to it --
# which is exactly what happened the first time this ran.
evictionHard:
  memory.available: "200Mi"
  nodefs.available: "300Mi"
  imagefs.available: "300Mi"
  nodefs.inodesFree: "5%"
EOF

kubelet \
  --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf \
  --kubeconfig=/etc/kubernetes/kubelet.conf \
  --config=/var/lib/kubelet/config.yaml \
  --cert-dir=/var/lib/kubelet/pki \
  --hostname-override="$NODE_NAME" \
  --container-runtime-endpoint=unix:///run/containerd/containerd.sock \
  --v=2 >/var/log/kubelet.log 2>&1 &

# Registered is not the same as Ready: the kubelet appears as a Node as soon as
# it has a certificate, and goes Ready when the runtime reports its network up.
n=0
until grep -q "Successfully registered node" /var/log/kubelet.log 2>/dev/null; do
  n=$((n + 1))
  [ "$n" -gt 1200 ] && { echo REGISTER_FAIL=1; tail -20 /var/log/kubelet.log; sleep 900; }
  sleep 0.1
done
echo NODE_REGISTERED_MS=$(elapsed)

echo NODE_UP=1
sleep 100000
