# Machines — the second mode

**Status: built through milestone 3, and shipped off by default.** A `Machine`
becomes a Ready node, `kubectl delete` takes it away again, and pods on two
machines reach each other — [milestones](#milestones) 1, 1b, 2 and 3 below.
Provisioning on demand (4), consolidation (5), mixed-cluster scheduling (6) and
GPU (7) are not built. An installed ferry carries all of it; `ferry machines
enable` turns it on. See [INSTALL.md](INSTALL.md).

This document was written before any of it existed and is kept as the design it
argued for, with each milestone marked as it landed and corrected where
building it proved the design wrong — which happened twice, both recorded in
milestone 3.

Ferry has one mode today: the pod is the virtual machine. This proposes a
second, where the *node* is the virtual machine and pods inside it are ordinary
Linux containers — declared as custom resources, sized explicitly, reconciled
by a controller on the Mac. The two run in one cluster and a pod lands in one
or the other by where it is scheduled.

```
mode 1   pod = VM       every pod its own kernel        isolation
mode 2   node = VM      many pods share a node's kernel  density
```

## Why a second mode

[Experiment 13](../experiments/13-shared-kernel-cost/FINDINGS.md) priced the
first one. A pod VM costs **225 MiB** of host memory before the workload does
anything, flat across 8, 20 and 24 pods, and it cannot be tuned away — at
`--pod-memory-mib` 256, 512 and 1024 the per-VM cost barely moves. At
Kubernetes' default `maxPods` of 110 that is ~24 GiB spent on kernels — three
quarters of the 32 GiB Mac it was measured on, before a single workload runs.
Which means the real pod ceiling is memory rather than the hypervisor's 128-VM
cap, and `maxPods: 110` is a promise the machine cannot keep.

[Experiment 16](../experiments/16-architecture-benchmark/FINDINGS.md) then built
the other side for real — containerd on overlayfs in one VM — and measured the
two against each other. The result is stronger than the case made here
originally, because two of experiment 13's limits turned out to belong to *its
stand-in for a shared kernel* rather than to shared kernels:

| | vm-per-pod | node-vm |
|---|---|---|
| marginal pod/container, idle | 226 MiB | ~17 MiB |
| 8 containers of one 190 MiB image | 3078 MiB | **1229 MiB** |
| ...and the slope per extra container | 384.8 MiB | **0** |
| containers in one VM | n/a | 40, unbothered |
| start per container | ~300 ms | ~45 ms |

The slope is the whole argument. Eight containers reading the same image cost
what one costs — on the host, on disk, and in the guest's own page cache — while
`vm-per-pod` pays another 384.8 MiB every time. So mode 2's saving is not just
one kernel instead of N; it is **one copy of every image instead of N**, which
grows with replica count and with image size.

The 22-container ceiling went the same way: it came from giving each container a
block device, and with containerd 40 run in one VM without complaint.

**That is the case for mode 2** — not that sharing a kernel is cheaper in the
abstract, but that it lets ferry stop reimplementing what Linux already does
well, and layer sharing is the part worth the most.

It also brings back what the VM boundary costs in capability: ephemeral
containers and `kubectl debug`, containers joining a running pod, node-level
metrics from the `pods` cgroup, conntrack that is actually reconciled.

## The model

A machine is declared, not started. Resources are part of the declaration.

```yaml
apiVersion: ferry.dev/v1alpha1
kind: Machine
metadata:
  name: worker-0
spec:
  cpus: 4
  memory: 8Gi
  disk: 60Gi
  image: ghcr.io/imaustink/ferry-node:1.34.0     # an OCI image, unpacked to ext4
  role: worker
  node:
    labels: {ferry.dev/mode: shared}
    taints: []
status:
  phase: Running                # Pending | Provisioning | Running | Deleting | Failed
  address: 192.168.66.12
  nodeRef: {name: worker-0}
  conditions: [...]
```

`ferry-machined` — a new native macOS process, alongside the control plane —
watches these, and for each one creates a VM, unpacks the image to a disk,
hands it a bootstrap configuration, and waits for the node to register. Delete
the resource and the VM goes away with it.

In practice most `Machine` resources are not written by a person: they are
created by the provisioner described below, in response to pods that have
nowhere to run. A hand-written `Machine` is the bottom layer and the thing to
build first, not the interface anyone is expected to live in.

Nothing about this is novel — it is the Cluster API shape (`Machine` +
an infrastructure provider that turns it into a VM). Keeping the spec close to
that vocabulary is deliberate: it is the model people already know from managed
Kubernetes, and it leaves the door open to being a real CAPI provider later
without redesigning the resource.

### Resources are immutable

[Experiment 14](../experiments/14-balloon/FINDINGS.md) measured what can be
changed on a running VM, and the answer bounds this design:

- A VM's memory **ceiling is fixed when it boots**. The memory balloon can
  shrink a guest below that and grow it back up to it, promptly — guest free
  memory went 3767 MiB to 222 and back within seconds — but never past it.
- CPU count has no runtime equivalent at all.
- Ballooning **does not return memory to the host**. The VM process's footprint
  did not move during an inflate, nor under 8 GiB of host memory pressure.

So `spec.cpus` and `spec.memory` are a commitment made at creation. Changing
them rolls the machine rather than resizing it in place, which is the Cluster
API model anyway: machines are cattle. Because untouched guest memory is nearly
free — a 4 GiB VM that allocates 1 GiB costs 1434 MiB, not 4096 — a generous
ceiling is cheap, and the balloon is available to hold a guest to `spec.memory`
without paying for it up front.

And it points at how capacity is actually managed here. **Deleting a VM is the
only thing that returns memory to the host.** The balloon does not, and nothing
else can. So the answer to a node that is the wrong size is not to resize it —
it is to make another one and let this one go.

## Nodes on demand

A fixed set of hand-declared machines inherits the worst of both modes: size
them small and workloads do not fit, size them large and the Mac pays for
memory nobody is using, with no way to get it back. The resolution is to stop
declaring nodes and start deriving them — a controller that watches what the
cluster cannot schedule and creates a machine shaped to fit it, then removes
machines that are no longer earning their memory.

This is Karpenter's model rather than the classic cluster autoscaler's, and the
difference matters here. A cluster autoscaler grows and shrinks pre-defined
node groups of fixed shape; Karpenter looks at the pending pods and provisions
a node shaped for them. Since ferry cannot resize a VM, "pick the right shape
at creation" is not a preference, it is the only option available.

```yaml
apiVersion: ferry.dev/v1alpha1
kind: NodePool
metadata:
  name: default
spec:
  image: ghcr.io/imaustink/ferry-node:1.34.0
  limits:                       # what the Mac will commit in total
    cpus: 12
    memory: 96Gi
  machine:                      # the shapes a machine may take
    cpus: {min: 2, max: 8}
    memory: {min: 2Gi, max: 32Gi}
  consolidation:
    emptyAfter: 60s
```

The loop:

1. Pods are `Pending` with `Insufficient cpu` or `Insufficient memory`.
2. `ferry-machined` bin-packs them into a proposed machine shape, bounded by
   `spec.machine` and by what the host has left under `spec.limits`.
3. It creates a `Machine`, the VM boots and joins, the scheduler places the
   pods — no simulation of a node that does not exist, because by then it does.
4. When a machine is empty, or its pods demonstrably fit on other machines, it
   is cordoned, drained honouring PodDisruptionBudgets, and deleted. The memory
   comes back to the Mac at that moment and not before.

### Why this works better here than in a cloud

The standard objection to just-in-time nodes is scale-up latency: in a cloud, a
pending pod waits 60–120 seconds for an instance to boot and join. Ferry's
numbers are nowhere near that. A pod VM reaches userspace in 0.12s and a real
Alpine pod in 0.33s; a node VM has more to do — containerd, kubelet,
registration, CNI — but it starts from a local image with no registry pull and
no network round trip to a control plane in another building. **Boot-to-Ready
is the number that decides how aggressive consolidation can be, and it should
be measured first** — if it lands in low single-digit seconds, nodes can be
treated as genuinely disposable, and a warm spare makes it feel instant.

### The host budget is the real constraint

Guest memory is lazily backed, so the sum of every machine's ceiling may exceed
the Mac's RAM and cost nothing — until the guests touch it, at which point
there is no way to un-touch it. Overcommitting ceilings is therefore safe to
*advertise* and dangerous to *use*, and the controller has to hold both numbers:
what it has promised, and what the host has actually backed. `spec.limits` is
the promise ceiling; the Mac's free memory is the real one, and a machine that
would cross it should fail to provision rather than take the machine down with
it.

Two smaller accounting notes. The 128-VM cap now bounds machines rather than
pods, which is no constraint at all at this scale — but in a mixed cluster,
pod VMs and node VMs draw on the same 128. And each node VM has its own
containerd content store, so the same image pulled onto N machines is stored
and cached N times; a registry mirror on the Mac, which is already on the pod
network, turns that from N pulls into N copies of a local fetch.

### What it fixes that mode 1 cannot

Experiment 14 showed a pod declaring `limits.memory: 2Gi` dying with
`MemoryError` at around 512 MiB, because its machine was sized by a node-wide
flag that knew nothing about the pod. Under a provisioner, a pod that does not
fit any current machine is the *input* to creating one that does. And a pod
larger than the host can back stays `Pending` with a reason the scheduler can
explain, rather than OOMing inside a guest for reasons Kubernetes cannot see.

## What runs inside

**Stock containerd and kubelet. Not `ferry-cri`.** This is the one decision
that everything else depends on. `ferry-cri` exists to make a pod out of a VM;
inside a node VM that work is already done by Linux, and reusing it would
import every limit experiment 13 measured — the 22-container ceiling, the
duplicated image cache, containers fixed at boot.

The node image is built and shipped as an OCI image and unpacked to an ext4
disk, which is machinery ferry already has (`EXT4Unpacker`, the image pull path
in `PodRuntime`). It carries the guest kernel ferry already builds, containerd,
a kubelet, and the standard CNI plugins — which
[experiment 11](../experiments/11-cni-on-macos/FINDINGS.md) already showed
running in ferry guests.

## What is reused

Most of the hard parts exist.

| piece | state |
|---|---|
| Native control plane on macOS | done — etcd, apiserver, controller-manager, scheduler |
| Node bootstrap | done — `ferry token create`, cluster-info, CA pinning, TLS bootstrap, CSR approval |
| Booting Linux VMs with devices and networking | done — `ferry-cri` does it per pod |
| Unpacking an OCI image to an ext4 disk | done — `EXT4Unpacker` |
| Per-node pod CIDR slices | done — the cluster CIDR is already sliced by node index |
| GPU over vsock | done for pods; needs a device plugin inside a node VM |
| `Machine` CRD + controller | **new** — `ferry-machined` |
| Node image build | **new** |

### Networking is simpler here, not harder

[Experiment 09](../experiments/09-multi-node/FINDINGS.md) found that vmnet
isolates its networks from each other, which is what forced the per-pod layer-2
switch (`PodSwitch`) for mode 1. Mode 2 does not hit that: put every node VM on
**one** vmnet network and they are mutually reachable at layer 2, because pods
on a single node already are today. Each node takes a pod CIDR slice, each node
VM gets routes to its peers' slices via their addresses, and cluster traffic is
ordinary routing between a handful of machines rather than a flooded switch
between a hundred pods.

### Cluster DNS is per mode, for now

Machines resolve through their own CoreDNS, behind a `kube-dns` ClusterIP that
kube-proxy answers on each machine — the ordinary Kubernetes arrangement, which
works here because a node VM has a kernel to program.

Mode 1's CoreDNS cannot serve them, and the reason is the same vmnet isolation
that shaped the rest of this section: it is a `ferry-cri` pod on the Mac's vmnet
network, machines are on a vmnet network of their own, and a pod inside a
machine has no route to it. Two CoreDNS deployments is the honest arrangement
until cross-mode pod routing exists, which is milestone 6.

They are named apart on purpose. Mode 1 already owns `Deployment/coredns` and
`ConfigMap/coredns` in `kube-system` and labels its pods `k8s-app: kube-dns`;
reusing those names replaces mode 1's DNS with a copy pinned to nodes it does
not have, and reusing that label makes the `kube-dns` Service load-balance
across pods half the cluster cannot reach — DNS that works intermittently,
which is worse than DNS that does not work.

## Which mode is the default, and what has to be true first

Mode 1 is the default today, and the reason is provisioning rather than
confidence.

The case for making mode 2 the default is real and gets stronger the smaller
the Mac. A pod VM costs 226 MiB idle whatever it runs, so `maxPods` is derived
from memory and a 16 GiB Mac advertises around 36 pods; mode 2's marginal
container is ~17 MiB and eight containers of one image cost what one costs.
Most people have less memory than the machine this was developed on, and for
them mode 2 is the difference between running their stack and not.

What blocks it is not that mode 2 is newer. It is that **a `Machine` has to be
declared, with a size**, and "nothing to size up front" is the thing ferry is
for. Defaulting to mode 2 as it stands would mean `ferry up` inventing a node
shape before knowing the workload, which is Docker Desktop's bargain with extra
steps — and it would do it on the mode whose whole argument is density, where
guessing too small is a cluster that cannot schedule and guessing too large is
the memory you were trying to save.

Provisioning removes the guess rather than relocating it. A pending pod that
fits nothing creates the machine it needs, sized to fit; consolidation gives the
memory back when it does not. At that point nothing is sized in advance in
either mode, the claim at the top of the README holds for both, and mode 2
becoming the default is a change of which node a pod lands on by default rather
than a change in what ferry asks of you.

So: **milestones 4 and 5 are the precondition, not a nice-to-have afterwards.**
Until they exist, a small Mac is better served by mode 1 advertising a low
`maxPods` honestly than by mode 2 asking for a number nobody has.

Worth saying because it is easy to lose: mode 1 does not go away when mode 2 is
the default. The Mac node is where the provisioner runs.

## How a pod chooses

It does not need a new concept. The Mac is a node and each machine is a node,
so isolation becomes node selection — which Kubernetes already expresses:

```yaml
nodeSelector: {ferry.dev/mode: shared}      # dense, shared kernel
nodeSelector: {ferry.dev/mode: vm-per-pod}  # one kernel per pod
```

Taint the Mac node so pods land on machines by default and opt in to
VM-per-pod, or the reverse, per cluster. This is better than the `RuntimeClass`
split considered earlier: no new admission behaviour, no runtime negotiation,
and `kubectl get nodes` shows the truth.

**Built.** The Mac node's kubelet registers `ferry.dev/mode=vm-per-pod`, and
`ferry-machined` labels each machine `shared` once its node appears —
`kubectl get nodes -L ferry.dev/mode`. The label was the missing half: this
document specified the selector before anything set it, so for a while the
selector above matched nothing on either side.

The machine's label is patched by the controller rather than registered by its
kubelet, which would be the race-free place for it. The kubelet inside a machine
is configured from the kernel command line, and putting a label there means
threading a value that is identical on every machine through `ferry-machined`,
`ferry-node`, the boot arguments and `init.sh`. The cost is a window of up to one
reconcile interval where the node is Ready and unlabelled, and a pod selecting
`shared` will not schedule there yet. That is the safe direction — the label is
missing rather than wrong, so the scheduler declines to place the pod rather
than placing it somewhere it does not belong.

Nothing balances between the two. A pod with no selector goes wherever it fits,
which is milestone 4's job to make deliberate.

## Milestones

1. ~~**One machine, by hand.**~~ **Done** —
   [experiment 17](../experiments/17-node-vm/FINDINGS.md). A VM carrying
   containerd, the CNI plugins and kubelet v1.34.11 joins the native control
   plane with a bootstrap token, is approved through a CSR, and goes **Ready in
   6.5 seconds**; pods scheduled to it run as ordinary Linux containers and
   reach Running in under a second once the image is present.

   The number settles the provisioner's shape: six seconds to replace a node
   means consolidation can be aggressive and warm pools are an optimisation
   rather than a requirement. It also produced most of the node image's
   specification, because four things stopped the node dead and none of them
   were about virtualization — a read-only `/proc/sys`, eviction thresholds
   sized for a Mac rather than a 2 GiB root filesystem, no `iptables` for the
   CNI plugin, and no `/etc/hosts` for containerd to copy. What it is *not* is
   a node image: the software is staged into a `ferry-cri` pod VM, which is
   exactly why those four bit.
1b. **The node image.** **Done** —
   [experiment 18](../experiments/18-node-image/FINDINGS.md). Docker builds it,
   `ferry-node build` unpacks it into an ext4 disk, and `ferry-node run` boots
   that disk as a machine with a vmnet address and its joining details on the
   kernel command line. Ready in **13.8s**, and pods on it now reach the
   internet, which the staged-into-a-pod version could not do for want of
   `iptables`. `ferry-node`'s two verbs are the shape `ferry-machined` needs:
   image in, machine out.

2. ~~**`Machine` CRD and `ferry-machined`.**~~ **Done** —
   [experiment 19](../experiments/19-machine-crd/FINDINGS.md). `kubectl apply` a
   `Machine` and a node is Ready **16 seconds** later; `kubectl delete` and it is
   gone in **3**, VM stopped, `Node` removed, disk and token cleaned up behind a
   finalizer. `kubectl get machines` reports the address once the machine has
   one and the node reference once the kubelet has actually registered.

   `ferry-machined` is Go beside the control plane and calls `ferry-node` for
   anything involving a VM, which is the split ferry already uses between
   `ferry-streamer` and `ferry-cri`.
3. ~~**Pod network between machines.**~~ **Done** —
   [experiment 20](../experiments/20-pod-network/FINDINGS.md). One
   `ferry-node serve` holds one vmnet network and hosts every machine on it;
   each node takes its `podCIDR` from the cluster and routes to the others'
   slices, read from the Node list with the kubelet's own certificate. A pod on
   one machine pings a pod on another.

   Two corrections to what this document assumed. A vmnet network belongs to
   the process that made it, so "one network" meant restructuring `ferry-node`
   into a server rather than configuring a subnet. And vmnet *does* carry
   pod-addressed traffic between machines on it — an earlier reading said
   otherwise and was taken against a pod that had already exited. A second
   interface per machine, switched by ferry, was built before that was noticed
   and has since been removed — it duplicated the kernel datapath, and the one
   case it was briefly kept for, traffic between two Macs, is the thing it could
   not do: it had neither the UDP relay nor the peer list that mode 1's
   `PodSwitch` carries.

4. **Provisioning on demand.** **Built, and not yet run against a cluster** —
   `ferry-karpenter`, Karpenter with ferry as its cloud provider. `Create`
   writes a `Machine` and `ferry-machined` makes it a node; `Delete` removes it.
   Instance types are synthesised from a shape range rather than read from a
   catalogue, and the host budget is enforced by refusing with Karpenter's
   insufficient-capacity error — the one part of a cloud provider a cloud never
   has to write, because a region does not run out when you ask for one more
   node. Started by `ferry machines enable` beside `ferry-machined`.

   This is what has to exist before mode 2 can sensibly be the default, because
   until a machine is created for you, choosing mode 2 means choosing a node
   size in advance. What is not yet proven is any of it running: the provider
   compiles against the interface and its arithmetic is tested, and no pod has
   yet caused a machine.
5. **Consolidation.** Cordon, drain honouring PDBs, delete — and the memory
   returns to the Mac. Without this half, provisioning is a one-way ratchet, and
   on a laptop a one-way ratchet is just a memory leak with a controller.
6. **Mixed cluster.** The Mac node and machines in one cluster, `nodeSelector`
   choosing between them, both modes running the same Deployment.
7. **GPU into machines.** A device plugin inside the node VM proxying to
   `ferry-gpud` over vsock — which is *more* standard than what mode 1 does
   today, since a real device plugin API exists inside a Linux node.

## Open decisions

- **Whose control plane?** Three answers, and the middle one is usually skipped.

  *Workers only*, which the staging above assumes: one CA, one apiserver, one
  pod CIDR, and the bootstrap flow that already exists, reused unchanged.

  *Control-plane machines*: `Machine` can carry `role: controlPlane`, so ferry
  provisions whole clusters. This buys per-cluster PKI, etcd inside a VM with
  its own durability story, per-cluster endpoints, and control-plane upgrades
  by rolling machines. HA would mean three etcd VMs on a Mac that is itself the
  single point of failure, so the availability is largely notional, and the
  native control plane stops being what ferry *is*.

  *Clusters with native control planes*: ferry already runs two independent
  clusters on one Mac — separate etcd, apiserver, controller-manager, scheduler,
  PKI, pod network and ports, keyed by checkout directory. A cluster therefore
  costs four processes rather than a VM, and only the workers need to be
  virtual. This is the managed-service experience — throwaway clusters, a
  cluster per branch, a 1.31 and a 1.34 control plane side by side — without
  giving up the thing that makes ferry distinctive.

  The destination is the third; the first step is the first. What the third
  needs is profiles promoted from a worktree-keyed convenience into a real
  interface, plus a resource to declare a cluster. Its binding constraint is
  vmnet — 32 networks for the whole Mac, held for about a minute after use
  ([experiment 07](../experiments/07-vmnet-leak/FINDINGS.md)) — which bounds
  concurrent clusters long before CPU or memory does. Keep `role` in the
  `Machine` spec so control-plane machines stay possible, but do not build them
  without a case that demands Linux.
- **Node image: build or adopt.** Building one keeps ferry's toolchain and
  ships as an OCI image. Adopting Talos gets an immutable, API-driven node with
  no SSH and a declarative machine config, at the cost of its opinions about
  how a cluster is formed. Building first is the lower-risk path; the interface
  (`spec.image`) is the same either way.
- **CAPI compatibility.** Ferry-native CRDs now, or the real Cluster API
  contract with `FerryMachine` as an infrastructure provider. Native is faster
  and CAPI can wrap it later; the cost of getting the spec shape wrong now is
  a migration.
- **Write the provisioner, or drive Karpenter.** Karpenter's provisioning and
  consolidation logic is a solved problem with a cloud-provider interface, and
  implementing that interface would be less code than reimplementing bin-packing
  and drain semantics. Against it: Karpenter runs as a pod, so it would live
  inside the cluster it provisions for, and its model assumes instance types
  from a catalogue rather than arbitrary shapes. Worth a serious look before
  milestone 4 — the shape of `NodePool` above is deliberately close to
  Karpenter's so that either answer stays open.

  **Decided: Karpenter**, built as `ferry-karpenter`. Both objections turned
  out to be smaller than they read, and one of them was simply wrong.

  *Running inside the cluster it provisions for* turned out not to happen at
  all, and this document was wrong to assume it. Karpenter v1 is a library with
  no webhooks, and ferry already runs its controllers as native macOS
  processes -- so `ferry-karpenter` is one more of them, talking to the cluster
  over a kubeconfig from outside it. There is no bootstrap problem, because
  nothing that makes nodes needs a node to run on, and no Linux image to build
  and publish for a controller.

  *A catalogue rather than arbitrary shapes* is a synthesis away. `GetInstanceTypes`
  can enumerate shapes from the `machine.cpus` and `machine.memory` ranges above
  — powers of two within the range is enough — and Karpenter will bin-pack
  against them. A hypervisor does not care that the shapes came from a list.

  The real adaptation is neither of those. **Karpenter assumes capacity is
  elastic** and a Mac's is not: `spec.limits` is a hard ceiling, and past it
  `Create` has to fail with an insufficient-capacity error so Karpenter marks
  the shape unavailable and backs off, rather than retrying into a machine that
  cannot be made. Getting that wrong is a hot loop against the hypervisor, and
  it is the part with no upstream precedent to copy.

  The argument against, which is not nothing: Karpenter is a large dependency
  for a laptop. Its sophistication — multi-zone, spot, instance-type arbitrage —
  is mostly inapplicable to one Mac with a handful of machines, while its
  operational surface is fully applicable: CRDs, a controller to keep running,
  and version skew with the Kubernetes it provisions for. A provisioner that
  said "pods are pending and do not fit, so make one machine big enough,
  respecting the budget; delete machines that have been empty for a minute"
  would be a few hundred lines. What argues against *that* is the second half:
  drain honouring PodDisruptionBudgets is where the bodies are buried, and
  Karpenter has already buried them.

## What this costs

Two runtimes to maintain, and a Linux node image becomes a build and
supply-chain problem for a project that until now shipped only Mach-O binaries
and a kernel. The README's claim — "no Linux host anywhere in the system" —
becomes true of mode 1 rather than of ferry, and that is the honest way to say
it. The test matrix doubles.

What it buys is a project that is no longer arguing for one point on the
isolation curve. The same cluster can hold a node where every pod has its own
kernel and a node where a hundred pods share one, and a workload picks. Neither
Docker Desktop, colima, kind, nor Orbstack can offer the first; nothing that
only does the first can be dense.
