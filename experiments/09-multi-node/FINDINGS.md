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

## What follows

**Same machine.** All pods of all nodes must sit on one vmnet network, since
that is the only place they can reach each other. One `ferry-cri` would serve
several kubelets, keeping one network and handing each kubelet only its own
sandboxes. No root, and provable from what is already working.

**Across machines.** Pods must be reachable from outside their vmnet network, and
vmnet will not do it. What the table above leaves open is that a pod *can* reach
the Mac's LAN address, and the Mac *can* reach its own pods -- so an overlay
terminating on each Mac and inside each pod is possible. ferry builds its own
guest kernel, so WireGuard could be compiled in and every pod given a cluster
interface. That is a real design and a large one.

Nothing here is blocked by ignorance -- the boundary is measured. It is a choice
about how much to build.
