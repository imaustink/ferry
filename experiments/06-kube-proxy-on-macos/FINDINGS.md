# Experiment 06 — kube-proxy's rule generation, on macOS

**Question.** ferry-netd reimplements a small slice of what kube-proxy does. Can
kube-proxy do the work instead — compiled for darwin and extended at a seam, the
way the kubelet was?

**Answer: yes**, and it is better than the reimplementation.

## What ferry-netd was missing

kube-proxy's nftables backend is 1903 lines to ferry-netd's ~150. The gap is not
mostly exotic features; it is behaviour that is *silently* wrong:

| kube-proxy | ferry-netd | symptom |
|---|---|---|
| `no-endpoint-services` → `reject-chain` | ✗ | a Service with no ready endpoints **hangs** instead of refusing |
| `mark-for-masquerade` / `masquerading` | ✗ | **a pod reaching its own Service** breaks — src == dst |
| `cluster-ips-check` reject | ✗ | traffic to a valid ClusterIP on a wrong port hangs |
| conntrack reconciliation | ✗ | traffic keeps flowing to a removed endpoint |
| session affinity, NodePort, traffic policies, UDP | ✗ | ignored |

More important than any single item: **who maintains the semantics**. kube-proxy
tracks EndpointSlice evolution, terminating endpoints, dual-stack and topology.
Reimplementing means owning all of that, and choosing to fail the conformance
tests that cover it.

## The seam

kube-proxy's nftables proxier talks to a `knftables.Interface`, and knftables
ships a `Fake` that records a transaction and can `Dump()` it. So the proxier can
run with nothing to program, and render what it *would* have programmed.

Three changes, all in the pattern already used for the kubelet:

| change | size |
|---|---|
| widen `pkg/proxy/nftables` to `linux \|\| darwin` | build tag |
| `ferry_conntrack_darwin.go` — stub, as macOS has no connection table | ~25 lines |
| `ferry_backend_{linux,darwin}.go` — real kernel, or the fake | ~20 lines each |

`proxier.go` is otherwise untouched, and the Linux build is unchanged.

## Result

`cmd/ferry-proxyd` builds for darwin/arm64, constructs the real proxier, is fed
one Service with two endpoints and one Service with none, and renders:

```
add chain ip kube-proxy reject-chain { comment "helper for @no-endpoint-services ..." }
add rule  ip kube-proxy cluster-ips-check ip daddr @cluster-ips reject \
            comment "Reject traffic to invalid ports of ClusterIPs"
add rule  ip kube-proxy endpoint-...__192.168.122.3/8080 \
            ip saddr 192.168.122.3 jump mark-for-masquerade
add rule  ip kube-proxy endpoint-...__192.168.122.3/8080 \
            meta l4proto tcp dnat to 192.168.122.3:8080
add rule  ip kube-proxy mark-for-masquerade mark set mark or 0x00004000
```

Full output in `rendered-ruleset.nft` — 57 lines, 11 of them reject or
masquerade rules that ferry-netd does not produce at all.

## And the ruleset transplants

Separately confirmed that a ruleset generated for one pod applies correctly in
another. A pod with ferry's own table removed could not reach a ClusterIP; after
loading kube-proxy's table it could:

```
after removing ferry's table:     UNREACHABLE
after transplanting kube-proxy's: in-guest-services
```

The rules are endpoint-specific rather than node-specific — `ip saddr <endpoint>
jump mark-for-masquerade`, `numgen random mod N vmap` — so the same ruleset is
correct in every pod. The only node-dependent structure is the `nodeport-ips`
set, which is empty without NodePort Services.

## What this replaces

ferry-netd should give way to:

1. `ferry-proxyd` on the Mac — native, one process, running kube-proxy's own
   generation against informers, rendering on each sync.
2. `ferry-cri` pushing the rendered ruleset into each pod, as it already pushes
   ferry-netd's.
3. Applying it in-guest with `nft -f`, which needs an `nft` binary in the pod —
   or `knftables.ParseDump` to replay it through netlink, keeping the existing
   static-binary approach and needing nothing in the image.

ferry-netd stays useful as the applier; what goes away is its rule *generation*.

## Reproduce

```sh
./build-kubelet.sh                 # applies the overlay, including these patches
"$TMPDIR/ferry-kubernetes-v1.34.0" -> go build ./cmd/ferry-proxyd && ./ferry-proxyd
```
