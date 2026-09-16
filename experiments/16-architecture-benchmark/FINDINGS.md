# Experiment 16 — The two architectures, measured against each other

**Question.** [docs/MACHINES.md](../../docs/MACHINES.md) proposes a second mode:
the node is the VM, pods inside it are ordinary Linux containers. Experiment 13
tried to price that idea but could only approximate it, by putting several
containers in one ferry-cri pod. That stand-in gives every container its own
ext4, which duplicates the image cache by construction — so its central finding,
"one kernel does not share the image cache", was a fact about ferry-cri rather
than about sharing a kernel.

This builds the real thing and measures both.

| architecture | what it is |
|---|---|
| `vm-per-pod` | N pod VMs, one container each — ferry today |
| `node-vm` | one VM running **containerd 2.3.5 + runc 1.5.1 on overlayfs**, N containers |

Both get the same image and the same workload. The node VM is given what the
pod VMs it replaces would have had between them, and guest memory is lazily
backed, so the larger configuration costs nothing it does not touch.

Run on macOS 26.6.2, Apple M1 Max, 10 cores, 32 GiB.

## Results

### The per-pod kernel is 226 MiB, again

| workload | n | vm-per-pod | per pod | node-vm |
|---|---|---|---|---|
| idle alpine | 8 | 1809 MiB | 226.2 | **722 MiB** |
| idle alpine | 20 | 4523 MiB | 226.1 | **923 MiB** |
| idle alpine | 40 | — | — | **1229 MiB** |
| touch alpine | 8 | 1877 MiB | 234.6 | **712 MiB** |
| touch alpine | 20 | 4693 MiB | 234.7 | **919 MiB** |

226 MiB idle, 234 MiB after reading the whole image, flat at every count and
reproducing experiment 13's independent run to within a tenth of a MiB. The
node VM's marginal container is about **17 MiB**.

### The image cache *is* shared — experiment 13 was wrong about why

The decisive measurement. Hold the node VM at one size, vary only how many
containers read the same `python:3.12-slim`, and watch the slope:

| containers | node-vm footprint | containerd disk | guest page cache | vm-per-pod footprint |
|---|---|---|---|---|
| 1 | 1229 MiB | 310 MiB | — | 382 MiB |
| 2 | 1229 MiB | 310 MiB | — | 766 MiB |
| 4 | 1229 MiB | 310 MiB | 715 MiB | 1539 MiB |
| 8 | 1229 MiB | 310 MiB | 716 MiB | 3078 MiB |

**The node VM's slope is zero.** Eight containers reading the same image cost
what one costs, on the host, on disk, and in the guest's own page cache — 716
MiB cached at eight containers against 715 at four. `vm-per-pod` is a straight
line at **384.8 MiB per pod** and never bends.

Experiment 13 measured a slope of 1267 MiB per container and concluded a shared
kernel does not share a cache. With a real containerd the slope is **0**. The
duplication was ferry-cri's ext4-per-container, exactly as suspected — and the
7.5 GiB of duplicated image it found is recoverable, but only by the
architecture that has an image store.

Note the measurement floor: `vmmap` reports gigabyte-scale footprints to two
decimals, so the node-VM column resolves to about 10 MiB. The slope is not
exactly zero; it is smaller than 10 MiB per container against a 190 MiB image.

### The 22-container ceiling was an artifact too

Experiment 13 found a VM would not boot with more than 22 containers, because
ferry-cri gives each one a block device and `Virtualization.framework` limits
those. With containerd there are no per-container block devices:

```
40 containers in one VM: started, 46 ms each, 1229 MiB, 15 MiB of disk
```

**40 with room to spare**, where the old shape died at 23. That ceiling belonged
to the stand-in, not to shared kernels.

### Starting a container: 46 ms against 300 ms

| architecture | 8 | 20 | 40 | per container |
|---|---|---|---|---|
| vm-per-pod | 2.41s | 6.21s | — | ~300 ms |
| node-vm | 0.36s | 0.41s | 0.51s | **~45 ms** |

Both are fast in absolute terms, and 300 ms per pod remains better than most
runtimes manage. But `vm-per-pod` is linear in pod count while the node VM is
nearly flat: forty containers start in about the time three pod VMs do.

## What this means

Experiment 13's conclusion — that a shared kernel recovers only the 225 MiB
kernel and nothing else — was an artifact of how it approximated a shared
kernel. The corrected picture:

- **Small pods:** the win is the kernel, 226 MiB each, exactly as before.
- **Fat pods:** the win is the kernel *plus the whole image cache*, once per
  image instead of once per pod. At eight containers of a 190 MiB image that is
  3078 MiB against 1229; the gap grows with every replica and with every
  megabyte of image.
- **Density:** the node VM's limit is memory, not device counts. 40 containers
  cost 1229 MiB, which is what five pod VMs cost.
- **The cost is a floor.** A node VM pays ~590 MiB for a guest OS and containerd
  before any container runs, plus its image store. Below about three pods of a
  small image, `vm-per-pod` is cheaper.

Which sharpens the case in docs/MACHINES.md rather than changing it. Mode 2 is
where density lives, and the reason is layer sharing more than kernel sharing.
The isolation argument for mode 1 is untouched by any of this — it was never a
memory argument.

### An operational limit worth recording

`ferry-cri` unpacks every container's rootfs into a **2 GiB** ext4
(`PodRuntime.swift`, `EXT4Unpacker(capacityInBytes: 2.gib())`). The full
`python:3.12` image — 1.4 GiB extracted — does not leave room for a Debian base
and containerd beside it, which is what forced this experiment onto
`python:3.12-slim`. Under `vm-per-pod` that ceiling applies to every pod: an
image much past ~1.5 GiB cannot be run at all, which rules out most ML images.
It is a fixed constant today, not a function of the pod's spec.

## Caveats

- **The node VM is a pod VM wearing a node's clothes.** containerd runs
  privileged inside a ferry-cri pod rather than in a purpose-built node image,
  so it inherits that pod's 2 GiB rootfs and its Debian base. The kernel, the
  hypervisor, the storage path and the overlayfs are real; the packaging is not.
  A real node image would start containerd at boot and size its own disk.
- **No kubelet.** This measures the runtime architecture — kernels, images,
  caches, start latency — not a Kubernetes node. Scheduling, CNI and the kubelet
  are milestone 1's business.
- **`vmmap` quantises** at ~10 MiB for gigabyte-scale footprints.
- **Registries throttle.** Docker Hub and ECR Public both returned 429 partway
  through a battery, which is why images are staged as local archives and
  imported. No registry sits in any measured path.
- **One machine, one run per cell**, on a Mac also running another cluster and
  Docker Desktop. Footprint is attributed by state directory, so foreign VMs do
  not land in the numbers, but they do consume headroom.

## Reproduce

```sh
./stage.sh        # containerd, runc, CA bundle
./prime.sh        # pull each benchmark image once, leave it as a local archive
./run-all.sh      # the battery, both architectures
./slope.sh        # the decisive one: cost per additional container
python3 summarize.py
```

`prime.sh` exports images inside a guest and copies them out through the shared
directory. Export straight onto the share produces an archive of blobs with no
`index.json`, which containerd rejects — so it writes locally first and copies.
