# Machines — the second mode

**Status: design. Nothing here is built yet.**

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

## Milestones

1. **One machine, by hand.** A node image that boots under
   `Virtualization.framework` and joins the cluster with an existing bootstrap
   token. Proves the image and the join; no controller yet. **Measure
   boot-to-Ready** — every decision about how disposable nodes can be rests on
   that number.
2. **`Machine` CRD and `ferry-machined`.** Create and delete a node by applying
   and deleting a resource. Status reflects the VM and the `Node`.
3. **Pod network between machines.** One vmnet network, per-node CIDR, routes.
   Pods on two machines reach each other; Services work.
4. **Provisioning on demand.** `NodePool`, pending-pod bin-packing, machine
   creation, and the host budget. A Deployment scaled beyond what exists
   creates the node it needs.
5. **Consolidation.** Cordon, drain honouring PDBs, delete — and the memory
   returns to the Mac. Without this half, provisioning is a one-way ratchet.
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
