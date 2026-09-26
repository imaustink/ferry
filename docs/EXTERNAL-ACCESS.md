# Reaching the cluster from outside

**Status: one Mac is solved. Several Macs are served, but you choose how
clients find a live one.**

A LoadBalancer on ferry needs nothing installed. `ferry-proxy` listens on the
Mac, 80 and 443 included and without root, and publishes the Mac's LAN address
as the Service's `EXTERNAL-IP` ([SERVICES.md](SERVICES.md#the-outside-edge-nodeport-loadbalancer-hostport)).
This page is about what happens after that: a router forwarding ports from the
internet to your ingress, and a cluster that spans more than one Mac.

## What ferry does today

**Every Mac serves every LoadBalancer.** Each Mac runs its own `ferry-proxy`,
listening at its own LAN address. A connection whose pod is on another Mac is
handed to that Mac's node port. So an ingress controller running on one Mac is
reachable at the LAN address of any of them.

**The Service names one of them.** Only the control-plane Mac publishes its
address in `status.loadBalancer.ingress`. A joined Mac authenticates as its
node, and a node may read Services but not write their status. If the
control-plane Mac goes away, `EXTERNAL-IP` still shows its address while the
other Macs go on serving.

**`externalTrafficPolicy` and `loadBalancerClass` are not read.** Every Mac
forwards to pods on other Macs whatever the policy says, and ferry claims every
LoadBalancer Service, including one that names another class.

## The problem

Anything that sends traffic to your cluster needs an address, and on more than
one Mac the right address is "whichever Mac is up". Two shapes of client meet
this differently:

- **The internet, through your router.** A port forward has exactly one
  destination. Public DNS points at your WAN address, which does not change
  when a Mac dies. The forward behind it has to.
- **Clients on your LAN.** They use a local name or a Mac's address directly.
  Whatever they resolved or were given is what they keep using.

On a single Mac none of this matters: forward to that Mac, done. Reserve its
address in your router's DHCP so the forward does not go stale.

## The options

### 1. Pick a Mac

Forward the router to one Mac's LAN address, or give LAN clients that address.
It works today, needs nothing, and every Mac serves every LoadBalancer, so it
does not matter where the ingress pods run.

**Losing that Mac loses the Service** until you point things somewhere else.
Everything below is a way of not doing that by hand.

### 2. An operator that rewrites the router's forward

A controller in the cluster watches the Service and keeps the router's port
forward pointed at the address it publishes. For UniFi,
[fiskhest/unifi-port-forward](https://github.com/fiskhest/unifi-port-forward)
does this: it forwards to the first IP in `status.loadBalancer.ingress`, or to
an address given by annotation, and follows it when it changes.

Nothing caches a port forward, so once the router has the new rule, every new
connection goes to the new Mac. Connections open to the dead one are lost, as
they would be anyway. The gap is how long it takes to notice:

```
Mac stops ──► node marked NotReady ──► published address moves ──► operator reconciles ──► gateway applies rule
              (tens of seconds,          (needs ferry change,
               kube-controller-manager's  see below)
               default grace period)
```

What it costs:

- **ferry has to move the published address.** Today it publishes the
  control-plane Mac and never anything else, so the operator has nothing to
  follow. This is [planned](#what-ferry-should-change), not built.
- **Port forwards are not in UniFi's official API.** These tools use the
  older internal `rest/portforward` endpoint, which Ubiquiti can change in
  any firmware. Pin the operator's version and check it after gateway
  upgrades.
- **The operator holds credentials that can rewrite your firewall.** Scope the
  API key as narrowly as UniFi allows.
- **Only the internet-facing path fails over.** LAN clients that use a Mac's
  address directly do not, unless your gateway loops them back through the WAN
  address (hairpin NAT), in which case they follow the same rule.

Other routers need their own operator. Anything with an API and a single
destination per forward works the same way.

### 3. DNS that follows the Macs

[external-dns](https://github.com/kubernetes-sigs/external-dns) writes the
addresses in `status.loadBalancer.ingress` to a DNS zone. With every live Mac
published, a name resolves to all of them, and a dead Mac drops out.

This is the option for LAN clients using a local name, and the weakest at
failover, because a record that changed is not a record clients have stopped
using:

- The change waits on the same detection as option 2, then on external-dns's
  sync interval (a minute by default).
- Resolvers, operating systems, browsers and runtimes each cache the old
  answer until it expires, and some keep it longer: resolvers with a minimum
  TTL, runtimes that cache for the life of the process, connection pools that
  never resolve again.
- A client given several addresses can move on to the next, but only fast when
  the dead one refuses. A Mac that is off or off the network refuses nothing;
  each attempt waits out a TCP connect timeout.

A short TTL, 30 seconds or so, keeps the stragglers few. It does not make them
none. Like option 2, it needs ferry to publish every live Mac.

### 4. A load balancer in front of the cluster

Put a small, always-on machine between the clients and the Macs, running
HAProxy, nginx, Caddy, Traefik or Envoy. It forwards to every Mac's LAN address
on the LoadBalancer's port, and health-checks each one. The router forwards to
it, once, and never changes; LAN clients use its address.

```
internet ──► router :443 ──► front LB ──┬──► mac1 :443  ferry-proxy ──► ingress pod
                                        ├──► mac2 :443  ferry-proxy ─┘
LAN clients ────────────────────────────┘
```

This fails over fastest of anything on this page. The load balancer probes
each Mac every few seconds and stops sending to one the moment it fails,
without waiting for Kubernetes to notice. Nothing downstream caches an answer,
so there are no stragglers. It needs no change to ferry and no root on any
Mac, and works with any router.

A TCP check on the Service's port is the right check. Every Mac listens on it
and forwards to wherever the pods are, so "this Mac answers" is the question
that matters. A Mac without the ingress pod is still a good target.

What it costs:

- **A machine that is not one of the Macs.** A Raspberry Pi, a NAS, a small
  VM on something that stays on. Running it on one of the Macs puts back the
  single point of failure it was meant to remove.
- **That machine is now the single point of failure.** A dedicated box doing
  one thing fails far less often than a laptop that sleeps and travels, but it
  can. Two of them sharing an address with keepalived (VRRP) removes it, at
  the cost of a second box.
- **You keep its backend list.** Adding a Mac to the cluster does not add it
  to the load balancer. Reserve every Mac's address in DHCP so the list stays
  true.
- **The edge sees the load balancer, not the client.** ferry holds outside
  clients to NetworkPolicy by the address they connect from
  ([NETWORK-POLICY.md](NETWORK-POLICY.md)). Behind a front load balancer that
  address is the load balancer's, for every client, so an `ipBlock` rule
  cannot tell your clients apart. If the load balancer terminates HTTP, it can
  pass the client in `X-Forwarded-For` for the ingress to read. The pod itself
  never saw the client's address, with or without this: `ferry-proxy` dials it
  from the Mac.

A minimal HAProxy for two Macs, TLS passed through to the ingress:

```
frontend https
    bind :443
    mode tcp
    default_backend ferry

backend ferry
    mode tcp
    option tcp-check
    default-server check inter 2s fall 2 rise 2
    server mac1 192.168.1.20:443
    server mac2 192.168.1.21:443
```

`fall 2` at 2 seconds takes a dead Mac out in about four.

### 5. An address that moves between Macs

This is what MetalLB's L2 mode does, done on the Mac instead of in a pod. Give
ferry a pool of spare LAN addresses. Each LoadBalancer gets one; the Macs elect
a holder for it through a Kubernetes Lease; the holder adds it to its network
interface and announces it with a gratuitous ARP. When the holder goes away,
another Mac takes the Lease and the address.

Clients and the router point at an address that never changes and always
answers, with no extra machine. Failover is the Lease timeout plus however
long LAN devices take to believe the ARP.

**It is not built**, and has real costs:

- Adding an address to an interface needs root on every Mac. The LoadBalancer
  path needs none today, and giving that up is a decision, not a detail.
- Some networks drop extra addresses on one port or one Wi-Fi client; managed
  and enterprise Wi-Fi often does.
- Every other option here can be checked with two profiles on one Mac. This
  one cannot: both profiles share one interface and one LAN address. It needs
  two physical Macs to test honestly.

## Side by side

| | failover | stale clients | extra hardware | root | ferry change | client address at the edge |
|:--|:--|:--|:--|:--|:--|:--|
| 1. pick a Mac | none | — | no | no | no | yes |
| 2. router operator | detection + reconcile | none | no | no | yes | yes |
| 3. DNS | detection + sync + caches | yes | no | no | yes | yes |
| 4. front load balancer | seconds | none | yes | no | no | no, the LB's |
| 5. moving address | Lease + ARP | few | no | yes | yes, not built | yes |

For a home cluster forwarded from a router, **4** is the strongest today and
**2** is the one that needs no extra box once ferry publishes every Mac. **3**
suits names used on the LAN, with caching understood.

## What does not work

**MetalLB.** Its controller would run, since assigning addresses is only API
calls. Its speaker cannot do its job. L2 mode answers ARP on the node's
interface, and a pod's interface is on a vmnet network whose only other member
is the Mac; the Mac's Wi-Fi or Ethernet is not bridged to it, so the answer
never reaches the LAN. In mode 1 there is no node network for a `hostNetwork`
speaker to sit on at all. BGP mode tells a router to send an address to a node,
and pod addresses are reachable only from the Mac that has them
([POD-NETWORK.md](POD-NETWORK.md)).

**Pods on the LAN directly.** That is vmnet's bridged mode, which needs
Apple's restricted `com.apple.vm.networking` entitlement.

Installing MetalLB anyway would also fight ferry: `ferry-proxy` writes its own
address into every LoadBalancer's status, replacing whatever MetalLB assigned.

## What ferry should change

None of this is built yet.

- **Publish every live Mac, in a stable order.** The control-plane
  `ferry-proxy` writes one entry per Ready Mac, preferring one that runs a pod
  of the Service, and keeps its first choice until that Mac fails, so the
  router is not rewritten for nothing. This is what options 2 and 3 follow.
- **Notice a dead Mac before Kubernetes does.** The control plane can probe
  each Mac's `ferry-proxy` directly and drop one that stops answering, rather
  than waiting out the node grace period. That shortens failover for 2 and 3.
- **Read `externalTrafficPolicy: Local`.** Forward only to pods on this Mac,
  and publish only Macs that have one.
- **Read `loadBalancerClass`.** Leave a Service that names another
  implementation alone, so ferry can coexist with one.
