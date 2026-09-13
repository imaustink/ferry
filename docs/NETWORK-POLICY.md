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
kernel. ferry has no CNI, and the Mac is not on the pod network at all -- so
there is nowhere on the host it could be done.

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
- `from`/`to` may be `podSelector`, `namespaceSelector` or `ipBlock`; ports may
  name a protocol and a port. An empty `from` means every peer; an empty `ports`
  means every port.
- An omitted `policyTypes` means Ingress, plus Egress if the policy has egress
  rules.

Return traffic is always allowed. A policy describes who may start a
conversation, not who may answer.

## One deliberate difference

**Ingress policies do not filter traffic from the Mac itself.**

Traffic arriving on a pod's `eth0` -- the vmnet interface -- is the node: the
kubelet's health probes, and connections forwarded in from a node port. The API
does not exempt those. ferry does, because dropping a probe does not isolate a
pod, it takes it down: a failed probe restarts the container, and the result
looks like a crash loop rather than a policy.

Most CNI plugins strike the same bargain. It is written here so it is a decision
rather than a surprise.

**Egress policies have no such exemption**, and restrict everything the pod
starts, including traffic to the internet -- which is what the API asks for. It
follows that a pod under a deny-all egress policy cannot reach cluster DNS unless
the policy allows it. That surprises people on every Kubernetes cluster, and it
is correct.

## Known limits

- **TCP, UDP and SCTP ports are rendered**, but only TCP has been tested.
- **`endPort` ranges are not implemented.**
- **Cross-machine enforcement is untested.** It should hold -- rules are applied
  at the destination pod, and peer addresses are cluster-wide -- but it has only
  been exercised on one Mac.
- Policy changes reach a pod in a couple of seconds, not instantly.
