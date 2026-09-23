# NetworkPolicy on ferry

**Status: enforced, inside the pods.**

```
BEFORE ANY POLICY
  client   -> server : REACHED-THE-SERVER
  stranger -> server : REACHED-THE-SERVER

WITH DENY-ALL INGRESS
  client   -> server : refused
  stranger -> server : refused

WITH from: role=allowed
  client   -> server : REACHED-THE-SERVER
  stranger -> server : refused

AFTER REMOVING THE POLICY
  stranger -> server : REACHED-THE-SERVER
```

## Where it is enforced

A NetworkPolicy is per pod: *this* pod accepts from *those* pods, on these
ports. On an ordinary cluster a CNI plugin enforces that somewhere in the host's
kernel. The Mac is not on the pod network at all, so there is nowhere on the
host it could be done.

> An earlier version of this page said "ferry has no CNI". That is no longer
> true: ferry runs real CNI plugins, on the Mac and inside pods, through
> `ferry-cni`. It does not change the argument below -- the plugin that would
> enforce policy is a Linux one, and where it runs is the pod's own kernel,
> which is exactly where ferry already puts these rules. `firewall` is a second
> path worth comparing against what ferry-netpol compiles today. See
> [experiments/11-cni-on-macos](../experiments/11-cni-on-macos/FINDINGS.md).

There does not need to be. Every ferry pod is a virtual machine with its own
Linux kernel, and ferry already loads nftables rules into those kernels: that is
how Services work. A per-pod policy wants a per-pod firewall, and a machine per
pod is a per-pod firewall.

So `ferry-netpol` watches policies, pods and namespaces, works out what each pod
should allow, and renders one nftables script per pod. `ferry-cri` splits that by
address and loads each pod its own section, through the same `nft` it already
uses for Services.

Selectors are resolved to addresses before they leave the Mac. A pod's kernel
knows nothing about labels, and nftables is perfectly happy with a set of
addresses -- which is also why a policy updates when a matching pod appears or
goes away.

## What it does

The API's own shape:

- A pod no policy selects is unrestricted.
- A pod any policy selects **for a direction** is default-deny in that direction,
  with the union of every matching rule allowed back in.
- `from`/`to` may be `podSelector`, `namespaceSelector` or `ipBlock`, and an
  `ipBlock`'s `except` is honoured. Ports may name a protocol, a number, a range
  with `endPort`, or a container port by name -- resolved against the pod for
  ingress, and against the peers for egress. An empty `from` means every peer;
  an empty `ports` means every port. A port name no container uses matches
  nothing.
- An omitted `policyTypes` means Ingress, plus Egress if the policy has egress
  rules.

Return traffic is always allowed. A policy describes who may start a
conversation, not who may answer. So is a pod talking to itself, over loopback
or its own address: containers in a pod share one network stack.

## Clients from outside the cluster

A NodePort, a LoadBalancer or a hostPort is a listener on the Mac, in
`ferry-proxy`, which dials the pod. So every such connection reaches the pod from
the Mac's own address on the pod network, whoever the client was -- and that is
the address the pod has to let in for its probes (below). Until this was
measured, the result was that **no ingress policy applied to any client of the
edge**:

```
                                      before      after
deny-all
  LAN        192.168.1.29:34345       served      refused
  pod -> node port 10.171.0.1:34345   served      refused    <- a pod laundering itself
  pod -> pod                          refused     refused
  web (probed on its own port)        Ready       Ready, 0 restarts
```

So the edge enforces the same policy, against the address the client actually
connected from, before it dials. `ferry-netpol` renders the rules once and
serves them twice -- as nftables for the pods, and as a small JSON document at
`/edge` that `ferry-proxy` follows the same way `ferry-cri` follows the rules.
The pod and the edge cannot disagree about what a policy means, because it was
resolved once.

Measured on a running cluster, with a LoadBalancer on port 80 and its node port
in front of a pod whose probes use a port of their own
([experiments/27-edge-policy-sctp](../experiments/27-edge-policy-sctp/FINDINGS.md)):

| policy | LAN :80 | localhost :80 | LAN node port | pod -> pod | pod -> node port | pod |
|---|---|---|---|---|---|---|
| none | served | served | served | served | served | Ready |
| `deny-all` | refused | refused | refused | refused | refused | Ready |
| `ipBlock: <LAN address>/32`, port 80 | served | refused | served | refused | refused | Ready |
| `ipBlock: 0.0.0.0/0 except <LAN address>/32` | refused | served | refused | served | served | Ready |
| `podSelector` naming one pod | refused | refused | refused | served | served (that pod) | Ready |
| a rule for port 81 only | refused | refused | refused | refused | refused | Ready |

A refusal at the edge is a reset, which a client sees as "connection refused".

The cost is one map lookup per connection -- a miss, for a pod no policy
isolates -- against a snapshot swapped in atomically, with no lock on the
connection path. Connection latency and throughput through the node port were
the same before and after within the noise of the measurement.

What the edge cannot do, and does not pretend to: **a connection this Mac
hands to another Mac's node port** reaches that Mac from this one's address,
and is checked there against this Mac, not the client. That is what
`externalTrafficPolicy: Cluster` means on any cluster: the source is rewritten
on the way through. A pod on another node *of the same Mac* is dialled directly
and checked against the real client.

A connection is only ever checked against policy on the Mac that has the pod.
`ferry-proxy` dials a pod directly only if it is on this Mac, and hands every
other connection to the node port of the Mac that has it, with no pod named,
so nothing is checked here (`chooseBackends` in `ferry-proxy/expose.go`). A
ClusterIP bound on the Mac has only this Mac's pods behind it. That is what
lets each Mac be served policy for its own nodes' pods alone, below.

## More than one Mac

Every policy is compiled on the control plane's Mac, by the one `ferry-netpol`
that watches the cluster with the cluster's own credentials. Its unix socket
serves this Mac's `ferry-cri` and `ferry-proxy`, which get every pod's rules:
every node on this Mac, `ferry node add` included, is this Mac's.

A Mac that joined cannot reach that socket, so the same `ferry-netpol` also
listens on a TCP port of its own (6444, shifted per profile like every other
port, one above the API server's). A joined Mac runs `ferry-netpol` as a
**follower**: it compiles nothing and watches nothing, asks that port for its
node's rules, and serves them on its own socket in exactly the two forms
`ferry-cri` and `ferry-proxy` already ask for. Neither of them changed.

**Authentication is the node's kubelet client certificate**, over mutual TLS.
The port accepts a certificate only if it chains to the cluster CA, is in group
`system:nodes` and is named `system:node:<name>` -- the three things the API
server checks before the Node authorizer calls a client a node -- and serves
it the rules for the pods on `<name>` and nothing else: its pods' nftables
sections, and its pods' entries in the edge document. The check is
`nodeauth.Node`, shared with `ferry-registry`'s peer port, which asks the same
question. The port presents the API server's own serving certificate, which a
joined Mac already trusts for that address, so a follower knows it is talking
to the control plane and not to any other node of the cluster. A Mac with
several nodes follows once per node, with each node's certificate, over one
HTTP/2 connection per node, and serves the union.

This replaced a ClusterRole, `ferry-node-netpol`, that `ferry token create`
bound to `system:nodes` so that a joined Mac's `ferry-netpol` could compile for
itself as the node. That let every kubelet credential in the cluster list
every pod, namespace, node and NetworkPolicy, which is more than the Node
authorizer grants a kubelet. It is gone: `ferry token create` no longer makes
it, and both `ferry up` and `ferry token create` delete it from a cluster that
has it. What a node now learns from policy that it could not ask the API
server for is the addresses its own pods' policies admit, which it has to have
to enforce them.

**Updates are pushed, not polled.** The control plane holds each follower's
request until that node's rules change -- each node has generations of its own,
so a node is woken by changes to its pods and not by every pod in the cluster
-- and the follower holds `ferry-cri`'s and `ferry-proxy`'s the same way.
Compilation is coalesced: an event marks the rules stale and one goroutine
compiles, where each event used to compile on its own informer's goroutine.

**When the control plane cannot be reached**, nothing changes on the joined
Mac. The follower publishes only what it received, so the last rules stay in
force in `ferry-cri`, in each pod's kernel and at the edge -- even rules the
cluster has since changed. It never publishes an empty or partial set: before
the first answer for every node it holds its callers and then refuses them, and
both consumers keep what they had when refused. It retries from 250 ms backing
off to 5 s, and says when it loses and regains the control plane in its log. A
pod that *starts* on the joined Mac while its rules cannot be fetched has no
section, and starts unfiltered, which is the same as a pod that starts while
`ferry-netpol` is down on a single Mac. A new pod needs the API server, which
runs beside `ferry-netpol` on the control plane's Mac, so the two are rarely
down apart.

A joined Mac on a ferry older than this runs the old `ferry-netpol`, which
loses its grant at the control plane's next `ferry up` and stops getting
updates. `ferry join` from this version is the way back. A joined Mac on this
version against an older control plane says that NetworkPolicies are not
enforced yet, rather than looking enforced.

Measured on a second profile joined to this Mac's cluster, the way experiment
34 did it ([experiments/35-netpol-follower](../experiments/35-netpol-follower/)):

| | before (own `ferry-netpol`, ClusterRole) | after (follower) |
|---|---|---|
| friends-only policy on the joined pod: pod -> pod / edge | refused / refused | refused / refused |
| the same, client labelled a friend | served / refused | served / refused |
| the same on the first node's pod (control) | -- | refused / refused, then served / refused |
| `can-i list networkpolicies -A` as the joined node | yes | no |
| ClusterRole `ferry-node-netpol` | present | absent |
| policy applied -> pod closed, median of 7 | 93 ms | 93 ms |
| policy applied -> edge refuses, median of 7 | 46 ms | 45 ms |
| policy deleted -> edge serves, median of 7 | 41 ms | 37 ms |
| `ferry-netpol` RSS on the joined Mac | 32.8 MB | 28.3 MB |

Node A's certificate is served only A's pods; the other node's certificate
only its own; no certificate and another cluster's kubelet certificate fail the
handshake. With the control plane's `ferry-netpol` stopped and a deny-all
deleted while it was down, the joined pod and its edge stayed closed for 40 s;
started again, the edge opened 0.64 s later and the pod 0.73 s later.

`kubectl auth can-i list pods --all-namespaces` as the joined node still says
**yes**, and not because of this: `control-plane/up.sh` binds the whole
`system:node` ClusterRole to `system:nodes` (`ferry:system-nodes`), which also
lets every node list every Secret. With that binding deleted by hand the
answers were `no` for pods, secrets, namespaces and NetworkPolicies, and policy
on the joined node still passed the checks above, so the follower needs nothing
from it. Removing the binding itself is a separate change: `ferry node add`
runs its kubelets with the first node's certificate, which the Node authorizer
alone would refuse.

In the same-Mac simulation both profiles' nodes have the Mac's LAN address, so
the joined profile's `ferry-proxy` counts the first node's pods as its own and
dials them directly, and it has no edge rules for them. Two real Macs have two
addresses, and hand those connections over instead.

## One deliberate difference

**Ingress policies do not filter traffic from the pod's own node.**

A node reaches its pods from its own address on the pod network -- the first
address of the slice it hands out, so `10.244.1.1` for a pod at `10.244.1.7`.
That is where the kubelet's health probes come from, and where the API server
comes from when it calls a webhook or an aggregated API such as metrics-server,
and where `ferry image build` reaches its builder. The API does not exempt those.
ferry does, because dropping a probe does not isolate a pod, it takes it down: a
failed probe restarts the container, and the result looks like a crash loop
rather than a policy. Cilium and Calico make the same exception for the local
host.

What it no longer covers is anyone the node is merely carrying. The edge is
policed at the edge, above. And only the pod's **own** node is exempt: another
node's address is a peer like any other, which is what the API says. It used to
be every node's, and before that everything outside the cluster CIDR as well --
which let every edge client in and made an `ipBlock` for an outside network mean
nothing.

The consequence worth knowing: a process on the Mac that dials a pod's address
directly, rather than through a Service's node port, is the node, and is let in.
`curl 10.244.0.5` from the Mac works under `deny-all`; `curl localhost:80` for
the same pod's LoadBalancer does not.

The address is worked out from the pod's own address rather than the node's
podCIDR, because the two can disagree: a node re-added under an old name keeps
the Node object and its podCIDR while its runtime takes a different slice.
Measured -- podCIDR `10.171.1.0/24`, pods on `10.171.2.x` -- and every probe was
dropped under `deny-all` until this changed. `ferry node add` now deletes a
stale Node of the same name and registers the new one with its runtime's slice
as its podCIDR, so the two agree there as well; this is the belt to that one's
braces, and still what holds on a joined Mac, whose podCIDR is the controller's.

This exemption was first written as "anything that did not arrive on `eth1`",
`eth1` being the cluster switch and `eth0` the vmnet interface the Mac is on.
That described where the node's traffic comes from correctly and where pod
traffic comes from wrongly: two pods on the **same node** reach each other over
`eth0` as well, because each node's slice is a route their kernels resolve
directly. The exemption therefore covered every same-node conversation. Matching
on the source address instead says what was meant.

**Egress policies have no such exemption**, and restrict everything the pod
starts, including traffic to the internet -- which is what the API asks for. It
follows that a pod under a deny-all egress policy cannot reach cluster DNS unless
the policy allows it. That surprises people on every Kubernetes cluster, and it
is correct. Loopback is exempt: a deny-all egress policy used to cut a pod off
from its own localhost, and a sidecar from the container beside it.

## Known limits

- **TCP is tested end to end, at the pod and at the edge.** UDP is checked at
  the edge per conversation, when the session to a pod is made. SCTP ports are
  rendered as `sctp dport`; SCTP itself works between pods (see
  [SERVICES.md](SERVICES.md)) but has not been run under a policy.
- **IPv6 `ipBlock`s** are carried to the edge, which listens on both families,
  and left out of the pods' rules, which are IPv4 -- pods have no IPv6 address.
- **Cross-machine enforcement works**, and so does same-machine. Both were
  measured on a two-node cluster: with a `deny-all` in place a pod refuses its
  neighbour on the same Mac and a pod on the other node, keeps passing its own
  node's probes, and refuses the edge.
- Policy changes reach a pod in a couple of seconds, not instantly, and apply to
  new connections: an established one is return traffic.
