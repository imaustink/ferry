# Services on ferry — design

**Status: implemented and verified.** `ferry-proxy` binds each ClusterIP on the
host and forwards to a ready endpoint.

```
from the Mac      curl http://<clusterIP>/            -> hello from pod VM
from a pod        wget -O- http://backend/            -> hello from pod VM
                  wget -O- http://backend.default.svc.cluster.local/
in-cluster        KUBERNETES_SERVICE_HOST=10.96.0.1:443 + SA token -> API server
```

The last one matters most: that is what client-go does by default, so
Kubernetes-native workloads now run unmodified.

### One quirk worth knowing

The vmnet gateway interface only exists on the host while at least one pod VM is
attached. With no pods running, the API server's advertised address is not
locally reachable and the `kubernetes` Service cannot be served -- the proxy
accepts the connection and then times out dialling the backend. It recovers as
soon as any pod starts. CoreDNS keeps its `KUBERNETES_SERVICE_HOST` override for
the same reason: it must be able to start before Services work, including when
ferry is running without root.

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

**This has since been fixed.** `kernel/build-kernel.sh` builds Apple's own kernel
configuration, which enables `CONFIG_NF_NAT`, `CONFIG_NF_CONNTRACK`,
`CONFIG_NF_TABLES` and `CONFIG_NF_NAT_MASQUERADE`. On that kernel a pod can
program its own NAT rules:

```
kernel: 6.18.5-ferry
DNAT RULE ACCEPTED
-A OUTPUT -d 10.96.0.99/32 -p tcp -m tcp --dport 80 -j DNAT --to-destination 127.0.0.1:8080
conntrack present
```

So options 1 and 3 are both available now. Option 3 remains the one worth
building: rules computed once on the host and pushed into each pod, rather than
a kube-proxy and an API watch in every pod. `LinuxPod.execInContainer` exists and
host paths are already shared into pods over virtiofs, so a static rule
programmer can be injected and run without adding a container.

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
