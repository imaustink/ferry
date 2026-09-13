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

## Across machines: measured on two Macs

Bridged is out, and the header says so rather than leaving it to measurement:
*"Using a VZBridgedNetworkDeviceAttachment requires the app to have the
com.apple.vm.networking entitlement"* -- restricted, and an ad-hoc signed binary
is killed for claiming it. Settled.

What was not settled was routing, so it was tried on a second Mac.

### Inbound works, with real pod addresses

One host route on the other Mac -- `route add -net 192.168.77.0/24 192.168.1.29`
-- and a pod inside the first Mac's vmnet network answers:

```
ping  : reachable
http  : reached-a-pod-on-the-other-mac
path  : 1  192.168.1.29      <- the Mac
        2  192.168.77.4      <- the pod inside it
```

No overlay, no entitlement, no datapath work. Two hops, real pod address.

### Outbound is NATed, and cannot be turned off

The other direction rewrites the source. A pod at `192.168.77.3` connecting to
the second Mac arrives as the *host*:

```
tcp4  192.168.1.67.9099  192.168.1.29.48676  TIME_WAIT
```

Kubernetes requires pod-to-pod traffic to preserve source addresses, so this half
has to be fixed for the routed model to be correct.

`vmnet_network_configuration_disable_nat44` looked like the fix and is not. With
NAT44 off there is no bridge interface for the network and no host route to it,
and a pod cannot reach even its own gateway:

```
Mac A -> its own pod : NO REPLY
pod -> its gateway   : fail
bridge for .77       : (none)
host route           : (none)
```

NAT44 is not merely address translation here -- it is what attaches the host to
the network at all. Removing it leaves an isolated L2 segment with no gateway.

### Where that leaves it

**Routed, accepting NAT on egress.** Everything works and pods reach each other
across Macs, but a pod sees its peer as the peer's *host* address. That breaks
the Kubernetes network model and anything reading a source address. Cheap --
essentially a route per node and `podCIDR` on the Node object -- and honest only
if the limitation is documented loudly.

**Own the datapath.** `VZFileHandleNetworkDeviceAttachment` carries raw
link-layer frames over a datagram socket and mentions no entitlement at all. ferry
attaches every pod VM to a socket, is its own switch, and spans machines by
relaying frames. Correct source addresses, and it dissolves every vmnet limit in
these experiments -- the 32-network ceiling, the minute-long reservation, the
isolation between networks. The cost is that every packet crosses userspace and
that DHCP, NAT and gateway become ferry's to provide. This is what socket_vmnet
and gvisor-tap-vsock do.

**WireGuard in the guest kernel.** ferry builds its own guest kernel, so pods can
carry a cluster interface natively. Local traffic stays on vmnet's kernel
datapath and only cross-machine traffic is tunnelled, which performs best of the
three and works beyond one LAN. Most to build: keys, per-pod configuration,
routes.

## A trap worth recording

`one.swift` answers "is this subnet free?" by creating the network and releasing
it -- and releasing starts a fresh reservation of about a minute. A retry loop
around it therefore never terminates: every check re-reserves exactly what it is
waiting for. It cost ten minutes of a spinning loop before anyone noticed. A
probe with a side effect is not a probe.

## Running it: a node must outlive the session that started it

Both halves work, but a node started over SSH fails in a way worth recording,
because nothing about the error points at the cause.

macOS grants access to the local network per launching session. An SSH session
ends when the command returns, and the kubelet it left behind loses the grant
with it -- while `ping` still answers, `/usr/bin/curl` to the same address still
returns 200, the route is correct, and a ferry binary run fresh *in a live
session* reaches the API immediately. Only the long-running process is cut off,
and what it reports is `connect: no route to host`.

Measured on the second Mac:

| | failures |
|---|---|
| launching session held open, 3 minutes | 0 |
| 20 seconds after that session ended | 6 (55 total) |

So `ferry join` refuses to run under SSH and says why. Run it from a Terminal on
the machine, where the session lasts as long as the window and macOS has someone
to show its prompt to.

The same mechanism explains an earlier red herring: the join itself always
succeeded, certificate and all, because the session was still alive for those few
seconds.

Unrelated but found on the way, and also worth fixing: a login shell on macOS
allows about a million open files and an SSH session allows 256. A kubelet wants
thousands, so ferry raises the limit itself rather than inheriting whatever it
was started with.
