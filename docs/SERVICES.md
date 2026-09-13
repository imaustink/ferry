# Services on ferry

**Status: implemented, inside the pods.** Each pod programs its own kernel with
the Service rules; nothing is proxied through the Mac and nothing needs root.

```
host proxy: not running        ClusterIPs bound on the host: 0

by name : in-guest-services          # http://backend/
by FQDN : in-guest-services          # http://backend.default.svc.cluster.local/
by IP   : in-guest-services          # the ClusterIP directly
kubernetes Service + SA token -> the API server
```

## How

A pod is its own virtual machine with its own kernel, so it can do its own NAT
— once the kernel is built with it, which is what `ferry kernel` is for.

`ferry-netd` is a 2.6 MB static Linux binary mounted read-only into every pod. It
reads a ruleset on stdin and replaces the pod's NAT table. `ferry-streamer`
computes that ruleset once, from one set of informers, and `ferry-cri` applies it
to each pod when it boots and whenever it changes.

Nothing is left running inside a pod, and nothing inside a pod watches the API.

`ferry-netd` gets `CAP_NET_ADMIN` for the length of that one exec, granted to the
process rather than to the container — the privilege stays on a binary ferry
ships and runs, not on the workload.

## Why not kube-proxy in each pod

It would work, and it was tried. The cost falls in the worst place for this
design: a process and an API watch per pod, tens of megabytes each, and a
kube-proxy that must start and sync before the pod can reach a Service. Pod
start is ferry's best number — roughly a third of a second — and that would
multiply it.

Computing the rules once on the host and applying them gives the same routing
for one binary, run on demand.

## Why not kube-proxy on the Mac

It cannot run there. kube-proxy is Linux-only and programs netfilter; macOS has
neither. That is the same reason the kubelet needed patching.

## The host proxy, now a fallback

`ferry-proxy` binds each ClusterIP as a loopback alias and forwards to an
endpoint. It is what ferry used before the NAT kernel existed, and it still runs
when the guest kernel cannot do NAT.

Its costs are exactly the ones the in-guest path removes: it needs root, to bind
ClusterIPs and to listen on 443 for the `kubernetes` Service, and every Service
connection hairpins through the Mac instead of going pod to pod.

## Known limits

- **TCP only.** UDP and SCTP Services are not programmed, so a UDP Service does
  not route. Cluster DNS is unaffected: pods reach CoreDNS at its pod address,
  which needs no Service.
- **No session affinity.** Connections are spread across endpoints with
  `numgen random`, the same mechanism kube-proxy uses for probability, but
  `service.spec.sessionAffinity` is ignored.
- **No NodePort or LoadBalancer.**
- **Rules are applied on a 3 second poll** rather than a watch, so a new Service
  takes a moment to reach existing pods.
