# What ferry does not do yet

Measured against minikube and kind, which are what people will compare it to.
Everything below was checked against a running two-node cluster rather than
assumed.

Most of the original list is closed. What is left is four features that are
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

- **SCTP on the node edge.** Pod-to-pod SCTP works, including through a
  ClusterIP -- see `docs/SERVICES.md`. A NodePort or LoadBalancer cannot: a node
  port is a listener on macOS and macOS has no SCTP sockets to listen with.
  ferry records that on the Service rather than leaving the port unserved, and
  there is no way around it short of a userspace SCTP stack.

  An earlier revision of this list said the guest kernel lacked
  `CONFIG_IP_SCTP`. That was assumed and wrong -- Apple's configuration enables
  it, and `build-kernel.sh` only verifies four NAT symbols rather than
  restricting the set. It also said macOS "has no SCTP sockets", which overstates
  things: macOS ships no SCTP *stack*, and whether a userspace one could serve
  the node edge is open, in issue #38.
- **Cluster upgrades.** No path from one version to another. `ferry build
  --kubernetes-version` changes what a *new* cluster is built from; it does not
  move a running one, and nothing drains, replaces or rolls back a node.
- **Dashboard**, **registry**, and the rest of the addon ecosystem. The addon
  mechanism exists -- `ferry addons list|enable|disable`, reading
  `addons/<name>/` -- and carries two. minikube has around thirty.
- **Choosing the Kubernetes version is a build input, not a promise.** `ferry
  build --kubernetes-version vX.Y.Z` exists and records what the kubelet was
  built from, so changing it forces a rebuild. Only v1.34.0 has been built and
  run. The patches in `patches/` are written against a particular tree;
  `build-kubelet.sh` verifies every seam it edits and fails loudly when one has
  moved, so a drifted version fails at build time rather than at runtime, which
  is the best that can be said for it.

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
