# What ferry does not do yet

Measured against minikube and kind, which are what people will compare it to.
Everything below was checked against a running cluster rather than assumed.

Most of the original list is closed. What is left is three features that are
honestly absent and one correction, which is worth reading first.

## A correction

The previous revision of this document reported that **a NetworkPolicy does not
reach pods that are already running**. That was the wrong diagnosis of a real
bug, and the difference mattered.

The symptom was that applying `deny-all` to a namespace whose pods were already
up changed nothing, while a pod recreated afterwards came up isolated. The
conclusion drawn -- rules are programmed only at pod start -- fit those two
observations and was wrong. What was actually happening is that ingress policy
exempted *anything that did not arrive on `eth1`*, intending to exempt the Mac's
health probes, and two pods on the **same node** reach each other over `eth0`.
So same-node traffic was never policed at all, at any point in a pod's life, and
the recreated pod appeared isolated for an unrelated reason.

The measurement that settled it: with `deny-all` in place, a pod on the same Mac
got through and a pod on the other Mac did not. That is fixed now, and the
current behaviour is in the last section.

The lesson is the one this document keeps relearning: two observations can be
consistent with a theory that is still wrong. Change one variable at a time and
re-measure rather than reasoning from the source.

## Expected, and missing

- **SCTP Services.** UDP is carried end to end now. SCTP is not: `ferry-proxy`
  skips it outright on the host edge, and the guest kernel is built from Apple's
  configuration plus four netfilter symbols, which does not include
  `CONFIG_IP_SCTP`. Both halves would have to change, and the kernel build is
  the slow one that needs Docker.
- **Dashboard**, **registry**, and the rest of the addon ecosystem. The addon
  mechanism exists -- `ferry addons list|enable|disable`, reading
  `addons/<name>/` -- and carries two. minikube has around thirty.
- **Choosing the Kubernetes version is a build input, and now also an upgrade
  input.** `ferry build --kubernetes-version vX.Y.Z` picks it, and one version
  now drives the kubelet, `ferry-proxyd`, the control plane and etcd together --
  before, the kubelet and the control plane had separate defaults that nothing
  reconciled, so asking for a version newer than the control plane's default
  produced a kubelet newer than the API server with nothing saying so.
  v1.34.0 and v1.34.11 have both been built and run, and a cluster moved
  between them in both directions. The patches
  in `patches/` are written against a particular tree; `build-kubelet.sh`
  verifies every seam it edits and fails loudly when one has moved, so a drifted
  version fails at build time rather than at runtime, which is the best that can
  be said for it.

## Upgrades, and what an upgrade does not cover

**Cluster upgrades work** -- `ferry upgrade plan|apply|node|nodes|rollback|
status`, documented in [UPGRADES.md](UPGRADES.md) -- and were run on a real
cluster rather than reasoned about. v1.34.0 up to v1.34.11, back down, and up
again:

- the control plane restarted against the same etcd data directory and the
  workload did not notice. Same pods, same names, same IPs, **zero restarts**,
  and their ages carried straight through the switch;
- the node drained with eviction, its kubelet was replaced while `ferry-cri`
  kept running, and it came back Ready at the new version and uncordoned;
- rollback took the cluster back to v1.34.0 -- same etcd minor, so nothing was
  restored from the snapshot and nothing written since was lost, which is what
  it says it will do;
- restarting with the checkout built at a *different* version started the
  cluster at its own recorded version and said so, which is the guard against a
  build quietly becoming an upgrade.

Underneath that, 100 assertions in `tests/` cover the store, the skew rules and
the cluster-version bookkeeping, and a separate suite does a real etcd
snapshot-and-restore round trip with the flags ferry passes.

Three bugs were found by running it, which is the argument for running it:

- the node upgrade read the kubelet's version as soon as the node went Ready,
  but a node object keeps the old kubelet's status until the new one posts its
  own -- so a node that had upgraded correctly was reported as not having;
- the summary afterwards listed local nodes under "nodes on other Macs",
  contradicting the line above it, because it filtered by version and not by
  which Mac runs them;
- the restart guard pointed at `ferry upgrade apply <older>`, a command that
  correctly refuses, instead of at `rollback`.

What is still only reasoned about is a **minor** bump. Everything above is
within v1.34, which drives every path except patch drift. A new minor means
porting `patches/`, and `build-kubelet.sh` failing loudly on a moved seam --
during the build, before anything is switched -- remains the best that can be
said for it.

Known limits, which are not bugs:

- **There is no zero-downtime control plane upgrade**, and there cannot be with
  one etcd member and one API server. The API is unreachable for a few seconds.
  Running pods are not touched.
- **A checkout has one `bin/`**, so every node on one Mac moves together. The
  roll is per Mac, not per node.
- **Nothing distributes binaries to another Mac.** `ferry join` already says to
  copy them from the first Mac; upgrades say the same.
- **A minor bump is a different problem** -- porting `patches/` -- and this
  machinery does not claim to solve it.

## Known, and deliberate

- **A LoadBalancer below port 1024 needs `ferry-proxy` running as root** --
  which is every ingress controller's 80 and 443. Ports at or above 1024 are
  served unprivileged. The Service still shows `<pending>` for its external
  address, but the reason is now recorded on the Service itself and shows up in
  `kubectl describe`, and the NodePorts work either way.
- **Ingress policies do not filter traffic from the node**, which is the same
  bargain most CNI plugins strike; dropping a health probe does not isolate a
  pod, it restarts it. Written down in `docs/NETWORK-POLICY.md`.

## Architectural, not oversights

- **macOS on Apple silicon only.** kind and minikube run on Linux, Windows and
  Intel Macs. ferry's premise is `Virtualization.framework`.
- **One container runtime.** No containerd/CRI-O/docker choice; `ferry-cri` is
  the runtime.
- **128 pods, shared with the machine.** Every other VM on the Mac takes a slot.
- **An image is loaded per node**, not cluster-wide. minikube has the same
  property per profile.
- **A volume is local to one Mac.** The PersistentVolume says so through node
  affinity, and a pod that comes back is sent to the node holding its data --
  which is correct, and still not the same as network storage.

## Works, and worth saying so

Verified on the running cluster:

- **NetworkPolicy**, on the same node and across machines. With `deny-all` a pod
  refuses its neighbour on the same Mac and a pod on the other Mac; with an
  `ingress.from.podSelector` it accepts the peer that policy names and refuses
  the rest, either side of the network. Policy changes reach pods that are
  already running.
- **Ingress.** `ferry addons enable ingress-nginx`, an `Ingress` with a host
  rule, and `curl -H 'Host: web.ferry.test' http://<mac>:<nodeport>/` answers
  HTTP 200 from the backend.
- **`kubectl top pods` and `kubectl top nodes`**, without
  `FERRY_HOST_CLUSTER_IPS=1`. The aggregated API is reachable because the Mac is
  on the pod network, and the node's CPU now comes from the Mach host port
  rather than being reported as zero.
- **Real CNI plugins**, on the Mac and inside the pod VM, through libcni's own
  `invoke.Exec` seam.
- **GPU.** Both nodes advertise `ferry.dev/gpu: 1`, the scheduler rations it,
  and a pod that asks gets Metal work done on the Mac's own GPU.
- **More than one cluster at a time.** Profiles derive from the checkout, so a
  second worktree runs a second cluster with its own state, ports and pod CIDR.
- **More than one node per Mac, and more than one Mac**, with pod-to-pod traffic
  keeping its source address across machines.
- **NodePort**, **LoadBalancer** above port 1024, **PersistentVolumeClaims**
  provisioned and reclaimed, **`ferry image load`**, **UDP Services**.
- `kubectl exec`, `attach`, `port-forward`, `logs`, `cp` · Services with
  kube-proxy's own rules, including reject and hairpin · cluster DNS · sidecars
  and init containers · ConfigMaps, Secrets, projected ServiceAccount tokens,
  emptyDir, hostPath, subPath · resource limits and securityContext
  capabilities · RBAC and ServiceAccount token auth, since the control plane is
  upstream.
