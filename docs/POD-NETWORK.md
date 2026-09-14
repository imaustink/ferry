# The pod network

Every pod's address is real: the Mac can reach it, other pods can reach it, and a
pod on another Mac can reach it, all at the address Kubernetes knows it by.

```
eth0  10.244.0.16/24     vmnet -- this node's slice, and the Mac is on it
eth1  10.244.0.16/16     ferry's switch -- the other nodes

default          via 10.244.0.1 dev eth0
10.244.0.0/24    dev eth0 scope link  src 10.244.0.16
10.244.0.0/16    dev eth1 scope link  src 10.244.0.16
```

## Two interfaces, one address

A pod has two NICs and the same address on both. Longest match decides which is
used: this node's own `/24` leaves by `eth0`, on vmnet's kernel datapath; the
rest of the cluster leaves by `eth1`, through ferry's switch. The source address
is identical either way, so a pod is one pod wherever it is talking to.

## Why the node's vmnet subnet is a slice of the cluster CIDR

This is the part that matters, and it took a wrong turn to find.

The first version put pod addresses only on ferry's switch. That is a segment
between pods, and **the Mac is not on it** -- so the host could not reach a pod at
the address the cluster knew it by. Everything the Mac does to a pod needed a
translation table: the kubelet's probes, `kubectl port-forward`, the host side of
NodePort and LoadBalancer. Each of those was a separate patch reading a file
mapping one address to another.

Aggregated APIs could not be made to work at all. `kubectl top` reads
`metrics.k8s.io`, which the API server does not answer -- it forwards the request
to a pod. The API server is a macOS process with no route to any pod, so the
request timed out no matter what was translated, and the only remedy was binding
ClusterIPs on the Mac, which needs root.

The Mac is already on every vmnet network, for free and without privilege. So the
node's vmnet network *is* its slice of the cluster CIDR. Pods get
`10.244.<node>.x` from vmnet itself, the Mac sits on that subnet natively, and a
pod is reachable from the host at its real address.

Three workarounds went away with it: the probe-address patch, ferry-proxy's
address translation, and the map `ferry-cri` published for them to read.

### What happens when vmnet will not give up the slice

The design depends on getting one particular subnet, and vmnet does not always
grant it. A network stays reserved for a while after the process using it stops,
and only 32 exist across the whole Mac, so a few restarts in a row can leave the
slice unavailable for longer than it takes to get annoyed about.

Falling back to another subnet is harmless while this Mac is the whole cluster:
the gateway changes, CoreDNS rolls out again, nothing else notices. With another
node in the cluster it is not a fallback, it is a partition. The other Macs route
`10.244.<node>.0/24` over the switch, this node keeps advertising that slice as
its `podCIDR`, and its pods are on some other network entirely -- so nothing
reaches them, TCP included, while every node still reports `Ready`.

So the two cases are treated differently:

- **No other nodes:** fall back at once, and say the pods are off the pod network
  and another Mac cannot join until this one starts on its slice.
- **Other nodes:** wait 90 seconds for the slice, then refuse to start. A node
  that cannot hold its slice has nothing to offer a cluster it cannot talk to.
  `FERRY_ALLOW_OFF_SLICE=1` overrides this and starts anyway, with a warning,
  because vmnet can stay exhausted longer than its documentation suggests.

Whether this node has peers is read from `$FERRY_HOME/peers`, which is why that
file lives with the cluster's state rather than in the run directory -- the
question is asked before there is an API server to ask instead.

## What each interface is for

| | eth0 (vmnet) | eth1 (switch) |
|---|---|---|
| this node's pods | yes, kernel datapath | no, longest match prefers eth0 |
| the Mac | yes | no |
| the internet | yes, vmnet NAT | no |
| pods on other Macs | no | yes, relayed over UDP |

## What it does not do

- **The Mac reaches pods on *this* node only.** A pod on another Mac is still
  behind that Mac's switch. Nothing on the host needs it: a kubelet probes its
  own node's pods, and the host side of a Service hands a connection for a remote
  pod to the Mac that has it.
- **An aggregated API must be served from the control-plane node** for the API
  server to reach it, for the same reason.
- The cluster CIDR must be a `/16` or wider, since each node takes a `/24` of it.
