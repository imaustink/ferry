# Services on ferry — design

**Status: designed, not implemented.** Pods run and are routable
(experiment 05); ClusterIPs are not yet.

## The problem

Nothing programs `10.96.0.0/16`. On a normal node kube-proxy watches Services
and writes nftables rules that DNAT a ClusterIP to a backend pod. Ferry has no
kube-proxy anywhere:

- **Not on the Mac.** kube-proxy is Linux-only, and macOS has no nftables. Even
  if it ran, the host is not on the path between two pods.
- **Not on a node.** There are no node VMs. The pods *are* the VMs.

What already works, from experiment 05:

- pod → pod, directly, on the vmnet segment
- pod → the Mac at the pod-network gateway (`ping` from a pod exits 0)
- the API server advertises that gateway, so `kubernetes` Endpoints is
  pod-reachable

So the routing substrate is in place. What is missing is the translation from a
virtual Service address to a real pod address.

## Three ways to do it

### 1. kube-proxy inside every pod VM

Each pod has its own kernel, so it can run its own kube-proxy and program its
own nftables. This is the only option that yields genuine kube-proxy semantics —
session affinity, topology hints, every Service type — because it *is*
kube-proxy.

The cost is per-pod. Each pod would carry the kube-proxy binary, a kubeconfig,
and a watch on the API server. At the 128-pod ceiling that is 128 clients
watching Services and EndpointSlices, plus the memory for each. It also means
every pod image must contain kube-proxy, or ferry must inject it — which means a
second rootfs mount per pod.

### 2. A userspace Service proxy on the Mac

Give each pod a route for the Service CIDR via the gateway, and run one proxy on
the Mac that accepts connections to ClusterIPs, resolves the Service to a
backend pod, and forwards.

One component, no per-pod cost, and it can start today because pod → gateway is
already proven. The Mac already has to watch the API for other reasons, so the
Service and EndpointSlice watches are cheap.

The cost is that all Service traffic hairpins through the host — pod to pod via
the Mac, rather than pod to pod directly. For a local development cluster that
is a latency question, not a correctness one, and the measured pod ↔ host
round trip is ~0.4 ms.

### 3. ferry-cri programs nftables in the guest

`vminitd`'s `SandboxContext` already exposes `IpLinkSet`, `IpAddrAdd`,
`IpRouteAddLink`, `IpRouteAddDefault` and `Sysctl`. If it also reached nftables,
`ferry-cri` could watch Services once, centrally, and push the resulting rules
into each pod VM — no kube-proxy process per pod, no watch per pod, and traffic
still goes pod to pod directly.

This is the best end state and the most work: ferry-cri becomes a Service
controller, and needs a rule-programming path into the guest that the current
API does not obviously provide.

## Measured: why option 1 is not available today

Running kube-proxy inside each pod VM was tested rather than assumed, and it is
blocked -- but not where expected.

Capabilities were the first suspicion and turned out to be fixable: the kubelet
never sent `ContainerConfig.Linux` on darwin, so `NET_ADMIN` never reached the
guest. Deriving that code path for darwin fixed it, and a pod now gets
`CapEff: a80435fb` -- the default set plus `CAP_NET_ADMIN`.

The real blocker is the guest kernel:

```
iptables -t nat -A OUTPUT ...
  Warning: Extension DNAT revision 0 not supported, missing kernel module?
  DNAT rejected

cat /proc/net/ip_tables_names   ->  no nat table
```

The kata-containers kernel has base netfilter compiled in but not the NAT
extensions, and it is monolithic -- no modules can be loaded. kube-proxy cannot
program DNAT in a pod that cannot do DNAT.

This is solvable by building a kernel with `CONFIG_NF_NAT` and the NAT targets,
which is the same road kiac walks for eBPF with its `--kernel full` option. Until
then option 1 is unavailable and option 2 stands.

## Recommendation

**Option 2 first, option 3 as the target.** Option 2 is a single component that
works on the substrate already proven, and it makes Services real for the
use case that matters — running a workload locally and reaching it. Option 3 is
where this should end up, because hairpinning every Service connection through
the host is the one genuinely unsatisfying thing about option 2.

Option 1 is the most faithful and the least suited to this architecture; a
per-pod API watcher does not belong in a design whose whole point is that pods
are cheap.

## DNS

CoreDNS runs as an ordinary pod, so it gets a pod IP like any other. Pods need
`nameserver <coredns ClusterIP>` in `/etc/resolv.conf`, which requires Services
to work first — or, as a bootstrap, ferry-cri can set
`LinuxPod.Configuration.dns` to CoreDNS's *pod* IP directly, which needs no
Service layer at all and would make DNS work before any of the above lands.

That is probably the right first move: it is small, it is independent, and
`Configuration.dns` is already in the framework and currently unused.
