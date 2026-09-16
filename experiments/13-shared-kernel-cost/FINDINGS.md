# Experiment 13 — What does a kernel per pod cost?

**Question.** Ferry gives every pod its own virtual machine. That boundary is
the whole design, but nobody had priced it. Is there a world where one shared
VM for all the pods is the better machine to build?

**Method.** Drive ferry's own CRI runtime into the two shapes and measure the
difference:

| shape | what it is |
|---|---|
| `vm-per-pod` | N sandboxes, one container each — ferry today |
| `shared-vm` | 1 sandbox, N containers — one kernel, N workloads |

Both run the same image and the same command, so the only variable is whether
each container gets its own kernel. The runtime is a `ferry-cri` of the
experiment's own, on its own socket, state directory and pod subnet, driven by
a CRI client rather than a kubelet: nothing reconciles behind the measurement.

Memory is macOS's `phys_footprint` for the VM processes — resident minus the
shared framework pages every VM maps a copy of. Ownership is settled by which
VM process holds a rootfs under this experiment's state directory, because a
cluster running on the same Mac starts pods mid-run and a naive process diff
counts them as ours. (It did, once, before this was fixed.)

Run on macOS 26.6.2, Apple M1 Max, 10 cores, 32 GiB, against `ferry-cri` at 0.45.0.

## Results

### A kernel costs 225 MiB, and that is the whole prize

Idle Alpine pods, doing nothing but existing:

| containers | shape | footprint | per container |
|---|---|---|---|
| 8 | vm-per-pod | 1802 MiB | **225.2 MiB** |
| 20 | vm-per-pod | 4506 MiB | **225.3 MiB** |
| 8 | shared-vm | 243 MiB | 30.4 MiB |
| 20 | shared-vm | 272 MiB | 13.6 MiB |

225 MiB per pod, flat across 8, 20 and 24 pods (224.8 / 225.3 / 225.5 in three
independent runs). Inside an already-running VM the marginal container costs
about **2.4 MiB**.

The cost does not come from the memory the pod was given. At
`--pod-memory-mib` 256, 512 and 1024 the resident size per VM was 285, 289 and
331 MiB — nearly flat. **This is the fixed price of a kernel and a hypervisor,
not a pod using its allotment**, so it cannot be right-sized away.

Experiment 03 measured 12.5 MiB per VM and concluded density was free. That
was a 1.6 MiB initramfs with a sleeping init. A real pod — OCI rootfs, vminitd,
a network interface, cgroups — costs **18x** that.

At Kubernetes' default `maxPods` of 110, the tax is **~24 GiB — on this 32 GiB
machine, three quarters of its memory spent on kernels before a workload runs.**
The pod ceiling here is therefore memory, not the hypervisor's 128-VM cap:
around 60-80 pods with nothing left over, against a `maxPods` that claims 110.
At a realistic 20-30 pods it is 4.5-6.75 GiB, which is 14-21% of the machine.

### The saving is a fixed amount per pod, not a fraction

Sized fairly — the shared VM given N x 512 MiB, what the pods it replaces would
have had between them, which costs nothing since guest memory is lazily backed:

| workload | n | vm-per-pod | shared-vm | ratio |
|---|---|---|---|---|
| idle alpine | 8 | 1802 MiB | 411 MiB | 4.4x |
| idle alpine | 20 | 4506 MiB | 590 MiB | 7.6x |
| touch alpine | 8 | 1870 MiB | 479 MiB | 3.9x |
| touch alpine | 20 | 4682 MiB | 753 MiB | 6.2x |
| reread 128 MiB | 8 | 2876 MiB | 1434 MiB | 2.0x |
| touch python:3.12 | 8 | 4308 MiB | 4096 MiB | **1.05x** |

Every row is the same arithmetic: the shared VM pays the pods' working sets
plus **one** 225 MiB kernel, and `vm-per-pod` pays the same working sets plus
**N** of them. The ratio looks dramatic when the working set is small and
vanishes when it is large. It is not a percentage — it is 225 MiB per pod,
whatever the pod is doing.

(The python row is both shapes hitting their memory ceiling rather than either
shape's demand — 512 MiB per pod against 4 GiB shared. The next section runs it
with room to breathe, and the arithmetic holds there too.)

Which means the shared kernel is worth most exactly where pods are cheapest:
idle system daemons, sidecars, CI shells. It is worth almost nothing for the
workloads a Mac is interesting for — the moment a pod's own working set is
measured in gigabytes, 225 MiB is rounding, and a fat pod amortises its own
boundary.

### One kernel does not share the image cache

> **Superseded by [experiment 16](../16-architecture-benchmark/FINDINGS.md).**
> This section is right about ferry-cri and wrong about shared kernels. The
> duplication measured below comes from the ext4-per-container stand-in used
> here, not from sharing a kernel: with a real containerd on overlayfs, eight
> containers reading the same image cost exactly what one costs — a slope of
> zero against the 1267 MiB per container measured below. The rest of this
> experiment stands; this inference does not.

The python row above says the shared kernel saved 5%, but both shapes were
capacity-bound there — 512 MiB per pod against 4 GiB shared — so neither was
showing demand. Giving each shape more memory than it can want settles it.
One container's unconstrained demand is `D`; eight should cost `D` if the cache
is shared and `8D` if it is not:

| | containers | VM size | footprint | per container |
|---|---|---|---|---|
| `D` | 1 | 4096 MiB | 1536 MiB | 1536 MiB |
| shared | 8 | 12288 MiB | **10138 MiB** | 1267 MiB |

`8D` is 10713 MiB after amortising the one kernel the eight now share. The
measurement is 10138. **The cache is not shared — it is duplicated eight
times, in one kernel.**

Ferry clones an ext4 per container, so N containers in one VM are N block
devices holding identical bytes, and a page cache is per device. Sharing the
kernel shares the cache *pool*, not the cache *entries*. What each container
saved was its own copy of the kernel, and nothing else.

Image-layer sharing — overlayfs over a shared read-only lower — is a separate
piece of work, and for fat images it is worth far more than the kernel: 7.5 GiB
of the 10.1 GiB above is the same python image, cached eight times. It is also
the piece `vm-per-pod` can never have, because separate kernels cannot share a
cache at all.

### 22 containers per VM, and then the VM will not boot

> **Also superseded by [experiment 16](../16-architecture-benchmark/FINDINGS.md):**
> the ceiling belongs to giving each container a block device, not to the VM.
> With containerd, 40 containers run in one VM without complaint.

| containers in one VM | result |
|---|---|
| 12, 16, 20, 22 | boots |
| 23, 24 | `VZErrorDomain Code=1`, VM failed to start |

The same class of limit as the 128-VM ceiling, one level down: each container
is a block device, and `Virtualization.framework` will only take so many. A
shared-kernel node would hit this at 23 pods — well under `maxPods` 110 —
unless containers stop being block devices, which is the same overlayfs work.

### Pod start: 0.31s each, or 0.06s each

| shape | 8 containers | 20 containers | per container |
|---|---|---|---|
| vm-per-pod | 2.53s | 6.21s | ~0.31s |
| shared-vm | 0.60s | 1.17s | ~0.06s |

5x, and linear in both shapes. In absolute terms both are fast: 0.31s per pod
is better than most runtimes manage with a warm image cache, and the 0.12s of
that which is kernel boot is the part the shared VM removes.

### A shared cache is a shared resource

Under-sized, the shared VM thrashes in a way separate kernels cannot. Eight
containers each writing and re-reading a 128 MiB blob in one 512 MiB VM:

| shape | warm re-read |
|---|---|
| vm-per-pod (512 MiB each) | 23-31 GB/s |
| shared-vm (512 MiB total) | 0.8-1.6 GB/s |
| shared-vm (4096 MiB total) | 22-28 GB/s |

Sized fairly the collapse disappears, so this is not an argument against
sharing — it is an argument that a shared node VM has to be sized for the sum
of its pods, and that one pod's working set can evict another's. Under
`vm-per-pod` a pod's cache is its own, and no neighbour can take it.

### CPU is not a factor

An idle pod VM sits at ~0.1% of a core. Twenty of them is ~2% — real, and not
worth a design decision.

## What this means for ferry

The measurement does not support replacing the VM boundary, and it does not
support pretending the boundary is free either.

- **The boundary costs 225 MiB per pod.** Flat, unavoidable by tuning, and the
  only thing a shared kernel actually recovers.
- **That is worth recovering for small pods and not for large ones.** Which is
  a per-workload judgement, and Kubernetes already has the vocabulary for it:
  `RuntimeClass`. Default stays VM-per-pod; an opt-in class lands a pod in a
  shared node VM. Kata and runc coexist in production clusters this way.
- **The first customers are ferry's own system pods.** CoreDNS and DaemonSets
  are trusted, idle, and per-node — the exact shape where 225 MiB is most of
  the cost, and where a kernel boundary buys nothing.
- **A shared-kernel node would be capped at 22 pods** until containers stop
  being one block device each.
- **The bigger efficiency lever is image-layer sharing, not the kernel.** A fat
  pod's cost is its page cache, duplicated per container today in either shape.
  Fixing that helps the shared VM enormously and `vm-per-pod` not at all, which
  is worth knowing before choosing where to spend effort.

## Caveats — do not over-read these numbers

- **`shared-vm` is not a node VM.** It is N containers in one pod VM: one
  network stack, no per-pod netns, no in-guest image store. A real shared-kernel
  node has to build those, and they are not free. This measures the floor of
  what sharing a kernel could save, not a design that exists.
- **`phys_footprint` is the hypervisor's accounting**, not the guest's. It
  tracks what the host has backed, which is the number that matters for
  density, but it cannot say what inside the guest asked for it.
- **Page cache is opportunistic.** A guest with room caches everything it reads
  and never reclaims, so a large VM's footprint is demand *or* capacity,
  whichever binds first. Both python cells were capacity-bound, which is why
  the dedup question needed its own run (`dedup.sh`).
- **One machine, one image pair.** Alpine is a floor and python:3.12 a
  mid-weight ceiling; a 4 GiB ML image would move the fat-pod row further
  against the shared kernel, not for it.
- **The runtime is ferry's, so its choices are in the numbers** — notably the
  ext4-clone-per-container, which is exactly what the cache finding is about.

## Reproduce

```sh
./runtime.sh start          # a ferry-cri of this experiment's own
go build -o build/shkcost . # the CRI client
./run.sh                    # the matrix
./run-fair.sh               # shared VMs sized as the pods they replace
./device-ceiling.sh 20 22 23 24
./dedup.sh                  # does one kernel cache an image once or N times
python3 summarize.py        # every result as one row
./runtime.sh stop
```

`runtime.sh` prefers a locally built `ferry-cri` and falls back to the
checkout's, since the VM and container paths this measures are the same code.
