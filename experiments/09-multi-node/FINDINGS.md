# Multi-node: what is cheap, and what is hard

Two questions, and they have opposite answers. Nodes are almost free. The pod
network between them is the whole problem.

## Nodes are cheap

In ferry the Mac is the node and the kubelet is a native process, so a second
node is a second kubelet with its own CRI runtime -- not a VM, not a container,
not a distribution. Done by hand against a running cluster:

```
NAME          STATUS   ROLES    AGE   VERSION
ferry-mac     Ready    <none>   7h    v1.34.0
ferry-mac-2   Ready    <none>   2s    v1.34.0
```

What a second node needs: its own kubelet port (10250 is taken), root dir, cert
dir, log dirs, CRI socket, streamer port, and its own `ferry-cri`. Scheduling
across them works immediately, because it is upstream:

```
POD                       NODE          IP
spread-...-h5tdj          ferry-mac     192.168.66.x
spread-...-s9cjb          ferry-mac     192.168.66.x
spread-...-vznmv          ferry-mac-2   192.168.150.3
```

This is a better position than kind's, where a node costs a container holding a
whole distribution. Here it costs a process.

## The pod network does not cross a node

A pod on one node cannot reach a pod on another:

| from a pod on node 2 | |
|---|---|
| its own gateway `192.168.65.1` | ok |
| the internet `1.1.1.1` | ok |
| **the Mac's LAN address `192.168.1.29`** | **ok** |
| the other node's gateway `192.168.64.1` | fail |
| a pod on the other node | fail |

This is not a misconfiguration. `net.inet.ip.forwarding` is already 1, both
networks are directly connected to the Mac (`bridge100` at .64.1, `bridge101` at
.65.1), and routes for both exist. The packets are dropped by vmnet, which
isolates shared-mode networks from one another while still NATing them out to the
world. Note the third row: the pod cannot reach the Mac at `192.168.64.1` but can
reach the same Mac at `192.168.1.29`.

Letting vmnet choose the subnets instead of pinning them does not change it --
`vmnet.h` suggests unpinned shared networks can talk to each other, and measured,
they cannot.

## Bridged mode would have solved it, and is closed

Every pod is a VM with its own NIC, so bridging pods onto the physical LAN would
make pods on different Macs directly reachable with no overlay at all -- something
kind and minikube cannot do, because their pods are not VMs. vmnet offers
`VMNET_BRIDGED_MODE` and names `en0` and `en7` as bridgeable here.

It is refused:

```
bridgeable interfaces: 2
  - en0
  - en7
bridged config refused with vmnet_return_t(rawValue: 1001)
```

`vmnet_network_create` does not do bridged mode -- the header describes bridging
as a property of `vmnet_start_interface` -- and the entitlement that governs it,
`com.apple.vm.networking`, is restricted: an ad-hoc signed binary claiming it is
killed at launch. Docker reaches it through a privileged signed helper.

## One vmnet network can be shared between processes

`vmnet_network_copy_serialization` and `vmnet_network_create_with_serialization`
exist precisely for this, and what comes back is not a mach port or a descriptor
-- it is a dictionary holding 120 bytes:

```
xpc type    : dictionary
contents    = "networkSerialization" => <data>: { length = 120 bytes }
```

Bytes travel. Written to a file by one process and read by others:

```
owner:  network up, 120 bytes written, holding
joiner: rehydrated 192.168.57.1 in a separate process
joiner: rehydrated 192.168.57.1 in a separate process
--- and with the owner gone?
joiner: rehydrated 192.168.57.1 in a separate process
```

A plain create of that subnet is still refused while the reservation lives, so
serialization is the sanctioned way in rather than a hole.

**This settles multi-node on one Mac.** Every node's `ferry-cri` shares one vmnet
network and allocates from its own slice of the subnet, so pods reach each other
the way they already do within a node. No overlay, no routing, no root, and no
restructuring -- each node keeps its own runtime process.

## Across machines: three candidates, not one

Bridged is out, and the header says so plainly rather than leaving it to
measurement: *"Using a VZBridgedNetworkDeviceAttachment requires the app to have
the com.apple.vm.networking entitlement"* -- which is restricted, and which an
ad-hoc signed binary is killed for claiming. That is settled. What is left is not.

**Route pod CIDRs between Macs.** The ordinary Kubernetes model: each node owns a
CIDR, each host routes peers' CIDRs at the peer's LAN address, forwarding does the
rest. The measurement that looked fatal -- a pod cannot reach another vmnet
network on the *same* Mac -- may not apply across machines, because a remote CIDR
is not a local vmnet network from the sending Mac's point of view; it is just an
address vmnet will NAT toward whatever the host's routing table says. Pods already
reach the LAN, and a Mac already reaches its own pods. Cheapest by far if it
holds. Needs root for routes, and a second Mac to confirm.

**Own the datapath.** `VZFileHandleNetworkDeviceAttachment` carries raw
link-layer frames over a connected datagram socket and mentions no entitlement at
all. ferry would attach every pod VM to a socket and be its own switch, which can
span machines by relaying frames. It also dissolves every vmnet limit in this
directory -- the 32-network ceiling, the minute-long reservation, the isolation.
The cost is that every packet crosses userspace, and that DHCP, NAT and gateway
become ferry's to provide. This is what socket_vmnet and gvisor-tap-vsock do.

**WireGuard in the guest kernel.** ferry builds its own guest kernel, so pods can
have a cluster interface natively. Local traffic stays on vmnet's kernel datapath
and only cross-machine traffic is tunnelled, which is the best performance of the
three, and it works across NAT and the internet rather than one LAN. It is also
the most to build: key distribution, per-pod configuration, routes.

The order to settle them is cheapest-first: try routing with a second Mac before
building anything.
