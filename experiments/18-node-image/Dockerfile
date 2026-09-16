# A Kubernetes node, as an image.
#
# Built as a container image because that is the tooling everyone has, and then
# unpacked into an ext4 disk a VM boots from -- it is never run as a container.
# The difference matters: this boots its own init, owns its own /proc, and has
# the packages experiment 17 discovered a node needs and a container image does
# not carry.
FROM public.ecr.aws/docker/library/debian:12-slim

# iptables: the CNI bridge plugin shells out to it for ipMasq, and portmap needs
#   it too. Without it every pod sandbox fails to set up its network.
# iproute2: the node configures its own interface at boot, because ferry's vmnet
#   networks have DHCP disabled and the address is assigned by the host.
# kmod, procps, util-linux: the ordinary furniture an init script expects.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        iptables iproute2 ca-certificates kmod procps util-linux curl \
    && rm -rf /var/lib/apt/lists/*

# The node's software, staged on the host so the image build does no network
# fetching of its own and the versions match the control plane.
COPY stage/kubelet /usr/local/bin/kubelet
COPY stage/runc /usr/local/bin/runc
ADD stage/containerd.tar.gz /usr/local/
ADD stage/cni-plugins.tgz /opt/cni/bin/

COPY init.sh /sbin/ferry-init

RUN chmod +x /usr/local/bin/kubelet /usr/local/bin/runc /sbin/ferry-init \
    && mkdir -p /etc/cni/net.d /etc/kubernetes /var/lib/kubelet /var/log /run

# Not an ENTRYPOINT anyone will use -- the kernel is told init=/sbin/ferry-init.
# It is here so the image is self-describing.
ENTRYPOINT ["/sbin/ferry-init"]
