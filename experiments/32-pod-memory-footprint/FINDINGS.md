# Experiment 32: where does an idle pod's 226 MiB go?

**Question.** Experiment 13 priced a pod VM at 226 MiB of host memory, flat,
whatever the pod does, and called it "the fixed price of a kernel and a
hypervisor". That number sets `maxPods` (72 on a 32 GiB Mac). Experiment 03 had
booted a bare VM for 12.5 MiB, so ~210 MiB of it is something ferry's boot path
touches. What is it, and how much of it can go?

**Method.** A `ferry-cri` of this experiment's own (`runtime.sh`), driven by
experiment 13's CRI client, so nothing reconciles behind the numbers. Host cost
is `phys_footprint` of each VM process, the same instrument as experiment 13,
with `footprint(1)` for the per-region breakdown. Guest cost is read from
inside a privileged pod: `/proc/meminfo`, slabinfo, the boot log, and
`fincore` on vminitd's own filesystem mounted a second time (which shares the
first mount's page cache). Every change was measured as a before/after pair on
the same Mac in the same hour.

Apple M4 Max, 16 cores, 128 GiB, macOS 26.6.2. ferry at `d321955`, kernel
6.18.5 from Apple's Containerization 0.45.0 configuration, `alpine:3.20`.

## Result

| idle pod, default 512 MiB VM | host footprint |
|---|--:|
| before (ferry at d321955) | **227 MiB** |
| virtio disks not rotational (read-ahead 8 MiB → 128 KiB) | 150 MiB |
| + kernel without display, KVM, hibernation, kexec, NUMA; 128 KiB log | **131 MiB** |

**−42%, flat with count:**

| idle pods at once | before | after | time to all running, before → after |
|--:|--:|--:|--:|
| 20 (CRI) | 227.2 MiB each | **132.5** | 5.24s → 5.53s |
| 60 (CRI) | 227.0 MiB each | **132.8** | 16.10s → 16.39s |
| 20 + CoreDNS (whole cluster, `ferry up`) | 235.0 MiB each | **139.7** | 4.4s → 3.9s |

60 idle pods went from 13.3 GiB to 7.8 GiB. One pod at a time, cold, ten
alternating runs: median **297 ms before, 277 ms after**, so no start-latency
regression. (The 20- and 60-pod bursts are 2-5% slower after, inside the
run-to-run spread of the single-pod samples, 245-562 ms.)

Bigger VMs gain more, from the two boot arguments below:

| VM size (pod limit + 256 MiB) | before | nonrot | + slim kernel | + boot args (final) |
|--:|--:|--:|--:|--:|
| 256 MiB | 219.4 | 145.5 | 126.0 | 125.5 |
| 512 MiB | 224.6 | 150.2 | 131.1 | **130.6** |
| 1 GiB | 267.4 | 191.5 | 171.6 | **141.6** |
| 2 GiB | 289.4 | 213.2 | 194.6 | **162.6** |
| 3 GiB | 377.6 | | | **187.4** |
| 4 GiB | 397.1 | 322.1 | 301.6 | **205.6** |
| 8 GiB | 480.5 | | | **290.7** |

MiB per pod, 4 idle pods per cell. vCPUs barely matter. 1, 2 and 4 vCPUs cost
129.1 / 131.1 / 135.1 MiB on the slim kernel, ~2 MiB each.

## Where it went

### 120 MiB was read-ahead into the guest agent

The breakdown of one idle stock pod, 229 MiB:

| | MiB | what |
|---|--:|---|
| guest memory the host has backed | 194 | `app-specific tag 1` |
| — page cache of `/dev/vda` (the init filesystem) | **120** | vminitd 60.6 + vmexec 59.4 resident |
| — kernel image (code, data, bss, init) | 31 | loaded whole by VZ |
| — kernel page map (`struct page` for 128 Ki pages) | 8 | scales with VM size |
| — slab | 12 | kernfs, kmalloc-4k, task_struct |
| — anon, stacks, page tables | 5 | vminitd's heap is ~3 MiB |
| host copy of the kernel, freed but cached by malloc | **28** | `MALLOC_LARGE (empty)`, 27.8 MiB = the vmlinux file exactly |
| Virtualization.framework itself | 7 | MALLOC_SMALL, dyld, stacks |

vminitd and vmexec are 83 MiB static Swift binaries. The guest read 120 MiB
of them in 78 requests, ~1.5 MiB each, and mapped only 24 MiB. The cause is
one line of virtio-blk. Every virtio disk is marked rotational, and for a
rotational disk with no optimal I/O size the block layer sets read-ahead to
twice the largest request, `read_ahead_kb=8192`. Page faults on a mapped file
read *around* the fault by the same window, so each fault into an executable
pulled up to 8 MiB. The pages are clean cache the guest would drop, and the
host keeps them anyway (below), so they are 120 MiB of every pod for as long
as it lives.

`kernel/patches/0001-virtio-blk-not-rotational.patch` removes the flag.
Read-ahead falls to the kernel's 128 KiB default, `/dev/vda` reads 46 MiB
instead of 120, and vminitd and vmexec are resident at 23-26 and 19-20 MiB.

Why 128 KiB and not less? This is vmexec cold start, the cache it leaves
behind, and its time, five runs each:

| read_ahead_kb | vmexec resident | cold `vmexec --help` |
|--:|--:|--:|
| 8192 (before) | 49.5 MiB | 6-9 ms |
| 1024 | 22.2 MiB | 5-6 ms |
| 256 | 15.4 MiB | 6-8 ms |
| **128** | **12.9 MiB** | 6-8 ms |
| 64 | 10.4 MiB | 8-10 ms |
| 16 | 9.3 MiB | 11-16 ms |
| 0 | 4.5 MiB | 43-50 ms |

128 KiB is where the time starts to climb. Below it each MiB saved costs
milliseconds per container start.

**Since experiment 36** only the init disk stays there. ferry-cri raises the
pod's own disks (images, scratch, disk emptyDirs, block claims) to 1 MiB once
the VM is up. See "Read-ahead on the pod's own disks" below.

**What it costs** is a cold sequential read of one large file. Reading 512 MiB
from the container's own rootfs, page cache dropped, five runs, gave a median
4.9 GB/s at 8 MiB read-ahead and 3.0 GB/s at 128 KiB (spread 2.1-3.4). A privileged pod that wants
the rest can write its own `read_ahead_kb`. (That was the disk layout before
experiment 31. The cost, and its fix, on today's layout are below.)

### The kernel image is paid for twice

Virtualization.framework reads the kernel into a malloc'd buffer, copies it
into guest memory and frees the buffer. But a freed large allocation stays in
libmalloc's cache, dirty and counted in the footprint: `MALLOC_LARGE (empty)`,
27.8 MiB, the size of `vmlinux-arm64` to the byte. So every MiB of kernel image
is two MiB per pod. A compressed `Image.gz` would have shrunk the host copy,
but VZ refuses to boot one (`VZErrorDomain Code=1`).

`kernel/slim.config` takes out what a pod VM has no hardware or use for: DRM
and framebuffers (no display is attached), KVM (Containerization does not
enable nested virtualization), hibernation, suspend, kexec and crash dumps,
NUMA, and the 2 MiB log buffer (128 KiB holds a boot log several times over).
Everything else of Apple's configuration stays, including netfilter, NFS/CIFS,
FUSE, squashfs, wireguard and BPF. The image goes from **27.8 to 19.5 MiB**,
and the pod from 150 to 131, which is 8.3 MiB saved twice plus some slab. It
was verified on a real cluster with a Service reached by DNS name through NAT
in the pod's own kernel, a NetworkPolicy blocking ingress, an emptyDir,
`exec`, and `/proc/config.gz` showing the fragment took.

The host copy may be released under memory pressure, since libmalloc flushes
that cache on pressure notifications. Simulating pressure takes
`memory_pressure -S`, which needs root, so it is untested and not counted on.

### Bigger VMs: a 64 MiB bounce buffer and huge pages

The per-pod cost grew steeply with VM size, to 397 MiB for a 4 GiB VM, where
the page map accounts for 64. The boot log and `/proc/meminfo` show two causes:

- **swiotlb.** Guest RAM starts at 0x70000000 (1.75 GiB), so any VM over
  2304 MiB reaches past 4 GiB and the kernel sets aside a 64 MiB bounce buffer
  for devices that cannot address above it (`software IO TLB: mapped ... (64MB)`),
  zeroed at boot. Nothing uses it. VZ's virtio devices do not negotiate
  `VIRTIO_F_ACCESS_PLATFORM`, so virtio bypasses the DMA API. With
  `swiotlb=noforce` an idle 4 GiB pod goes from 271 to 206 MiB, with the
  network (an `apk add`) and disks verified at that size, and on the cluster a
  3 GiB-limit nginx serving through its Service.
- **Transparent huge pages.** Below 512 MiB of RAM the kernel leaves THP off
  by itself, which is why the default pod never showed it. Above, something in
  the guest's boot path asks for huge pages and gets twelve, 24 MiB of anon
  where there had been 3. With `transparent_hugepage=never` an idle 2 GiB pod
  goes from 196 to 166 MiB.

Both are boot arguments, which ferry-cri now passes to every pod
(`PodRuntime.podKernelArgs`). `--kernel-args` adds more for experiments. What
remains of the slope is ~21 MiB per GiB of VM: the page map (16 MiB per GiB,
64 bytes per 4 KiB page) and hash tables sized from RAM, all zeroed at boot.
A 16 KiB-page guest would cut the page map by four and was not tried, because
it changes what userspace sees and some allocators still assume 4 KiB.

## Read-ahead on the pod's own disks (experiment 36)

The memory above was all on `/dev/vda`. The throughput cut fell on the other
disks. Experiment 36 (`../36-per-disk-read-ahead/`, the same harness under
other names, ferry at `1cec4dd`, same Mac) measured those disks separately.

**Which disk is which.** The framework attaches the init filesystem first, as
`vda` (it boots `root=/dev/vda`), then every pod volume, and records each
volume's device letter in the VM instance's mount table under the pod's id.
From a real cluster pod with a disk emptyDir, a memory emptyDir and a
ReadWriteOnce claim: `vda` init (ro), `vdb` emptyDir, `vdc` the claim's block
image, `vdd` the image (ro), `vde` scratch. The memory emptyDir is a tmpfs
with no device. The order after `vda` changes with the pod (in the harness the
image is `vdb`), and read-only does not tell the init disk from an image, so
ferry-cri reads the devices from the mount table and does not guess.

**Memory.** This is host footprint per pod, with image and scratch read-ahead
varied and the init disk at 128 KiB. It is 4 pods a cell, three passes,
medians. Pods are idle after a working start. nginx:1.27-alpine and
python:3.12-slim (a spread of stdlib imports, SQLite, 20 requests to itself)
and node:22-alpine each serve 20 requests.

| read-ahead | alpine `sleep` | nginx | python | node |
|--:|--:|--:|--:|--:|
| 128 KiB | 134.9 | 144.9 | 182.4 | 198.4 |
| 512 KiB | | | | 209.8 |
| **1 MiB** | **134.1** | **146.9** | **186.8** | **215.4** |
| 2 MiB | 134.3 | 147.2 | 186.8 | 221.6 |
| 4 MiB | 134.6 | 146.9 | 186.5 | 230.4 |
| 8 MiB | 134.8 | 147.3 | 186.9 | 246.4 |

Passes agree within 1.5 MiB. Small files cost 0-4 MiB at any value, since a
fault reads at most the file. node's binary is one 120 MiB file, and faults in
it read around by the whole window, which is what vminitd did above. Any
workload that is one large executable will behave the same way.

**Throughput.** Cold on both sides: an image with a 2 GiB random `/big`, whose
ext4 was replaced by an APFS clone of itself before each pod, so the Mac had
none of it cached. Each setting read its own unread 192 MiB stretch. Ten pods,
order rotated. The writable-disk column is a file on the scratch disk, which
is the same kind of disk as an emptyDir or a claim. The Mac had that file
cached, since the guest had just written it. Medians in GB/s:

| read-ahead | image, cold, 64 KiB reads | image, cold, 1 MiB reads | image, Mac-cached, 64 KiB | writable disk, 64 KiB |
|--:|--:|--:|--:|--:|
| 128 KiB | 3.0 | 5.2 | 4.8 | 4.3-6.8 |
| 512 KiB | | | | 11.0 |
| **1 MiB** | **5.1** | 4.0 | **14.4** | **14.6-15.2** |
| 2 MiB | 5.5 | 5.2 | 16.6 | 15.8 |
| 8 MiB | 5.5 | 5.1 | 16.2 | 15.6 |

Cold reads spread 2.1-6.0 GB/s from run to run. Read-ahead sets the size of the
disk requests that a *small* read turns into. A 1 MiB read goes to the disk as
1 MiB whatever the setting, and the device takes up to 4 MiB a request. So the
1 MiB column hardly moves, and the 4.9 → 3.0 above (`dd bs=1M` from a
per-container clone, before experiment 31) does not reproduce on the current
layout. A program reading 64 KiB at a time got a third of the throughput at
128 KiB. At 1 MiB it gets 87-100% back, and at 2 MiB all of it.

**The choice is 1 MiB.** That gives 94% of the cold best and 87% of the cached
best. It costs alpine, nginx and python 0-4 MiB. For node it is the knee:
17 MiB more, against 24 at 2 MiB and 48 at 8 MiB. A workload that streams
large files can ask for more with the annotation.

**Mechanism.** After `create()` returns, ferry-cri opens one connection to
vminitd. Over it, it sends one `writeFile` of `/sys/block/<dev>/queue/read_ahead_kb`
for each pod disk, all together, while the containers are being added. The
boot waits for them before it returns, so before any container process starts.
There is no process in the guest.

- The value is `--pod-read-ahead-kb`, default 1024, which `ferry up` passes
  from `FERRY_POD_READAHEAD_KB`.
- A pod's `ferry.dev/read-ahead-kb` annotation wins for that pod. The kubelet
  copies pod annotations onto the sandbox config, so this needs no lookup
  through ferry-streamer.
- `WriteFileFlags` has no public initializer. The all-false value is built
  from three zero bytes, and if the struct changes size the write is skipped
  with a warning. A failure never fails the pod.

Verified on a cluster: every disk above at 1024, `vda` at 128, and the
annotated pod at 4096. The kernel patch stays as it is, because vminitd has
faulted itself in before any agent call could lower `vda`.

**Its cost.**

- Single cold pod starts, 20 each way, alternating with the runtime from before
  this change: median 290 ms before and 295 ms after. The ranges were 272-378
  and 262-371.
- In a burst of 20 pods, the writes finished a median of 3 ms (at most 10 ms)
  after the containers were added. Time to all running was 5.78 s before and
  5.88 s after.
- The dial takes the VM instance's lock, which adding a container also takes,
  so the writes cannot hide completely behind it.
- 20 idle pods: 135.5 MiB each before and 135.3 after. The 135 against 132.5
  above is the old runtime too, on the same Mac, so it is today's baseline.

**Not taken: a kernel boot argument.** The alternative was
`virtio_blk.read_ahead_kb=`, handled in ferry's own patch and applied to every
disk but the first. It costs nothing at runtime, but:

- every checkout would need `ferry kernel` (Docker) before it took effect;
- the changed kernel inputs would send a checkout that has not rebuilt back to
  the 226 MiB `maxPods` figure;
- "not the first disk" is a rule the kernel would have to trust, while
  ferry-cri knows which disk is which.

If the few milliseconds ever matter, this is the fix.

**Did not work:**

- Reading the image disk raw (`dd if=/dev/vdb`). The image ext4 is sparse, so
  those reads are holes returned at 16 GB/s.
- vminitd's sysctl RPC as a route to sysfs. It maps every `.` in a key to `/`
  under `/proc/sys`.
- A cold read of a writable disk. Dropping the Mac's cache takes `purge`, which
  needs root. The read path is the same virtio disk as the image's.

```sh
cd experiments/36-per-disk-read-ahead
./probe-at.sh final-map probe-map.sh 2        # the disks and their read-ahead
./memory.sh 3 4; ./memory.sh 3 4 "128 1024 2048 4096 8192" node
./seq-cold.sh 10                              # IMAGE: an image with a 2 GiB /big
HOLD=40s ./probe-at.sh seq-volume probe-seq.sh
./latency.sh 10; ./density.sh 20              # need build/ferry-cri-before (bin/ferry-cri at 1cec4dd)
./summarize.py results/memory*.txt results/seq-*.txt
kubectl apply -f cluster-check.yaml           # against `ferry up`
```

## What did not work

- **The balloon still returns nothing.** Experiment 14's probe was re-run here
  on a 2 GiB VM, with 1 GiB touched and released and the balloon inflated to
  leave the guest 256 MiB (guest free fell from 1921 to 141 MiB). The footprint
  was 1126 MiB before, during and after. VZ does not hand ballooned pages back
  to macOS, and has no free-page-reporting device. Dropping the guest's page
  cache in a running pod (124 → 25 MiB cached) likewise moved the footprint by
  0. Nothing a guest gives up after touching it comes back, so the only option
  is not touching it.
- **A compressed kernel.** `VZLinuxBootLoader` refuses it, as above.
- **Fewer vCPUs.** 1 vCPU saves 2 MiB against 2.
- **Less read-ahead than 128 KiB.** The table above shows it costs
  milliseconds per container start for each MiB saved.

## What is left, 131 MiB

| | MiB |
|---|--:|
| page cache: vminitd + vmexec (Apple's two static agents) | ~45 |
| kernel image in the guest | ~21 |
| host copy of the kernel, cached by malloc | 19.5 |
| slab | ~12 |
| page map at 512 MiB | 8 |
| Virtualization.framework | ~8 |
| anon, stacks, page tables, the container rootfs's cache | ~7 |

(`footprint(1)` of a final idle pod: 103 MiB guest memory, 20 MiB
`MALLOC_LARGE`, the rest VZ.) The largest remaining piece is the guest agent,
two copies of the same Swift runtime and Foundation in two binaries whose page
cache cannot be shared. A multi-call vminit (one binary, two names) would
roughly halve it. That is a change to Apple's `vminit` image, which ferry takes
as-is (`--init-image`), and was not attempted.

## The shared kernel

Experiment 13's opt-in shared kernel exists. It is mode 2, where the node is a
VM and pods share its kernel, chosen per pod with
`nodeSelector: {ferry.dev/mode: shared}` (docs/MACHINES.md). Its marginal
container is ~17 MiB against this experiment's 133, so it remains the answer
for dense, trusted, idle pods. The gap narrows from 13x to 8x.

## What changed in ferry

- `kernel/patches/` and a hook in `kernel/build-kernel.sh` that applies them
  after Apple's `build.sh` unpacks the source (spliced in after the line that
  copies the configuration; the build stops if that line moves).
- `kernel/slim.config`, appended to every build.
- `vmlinux-arm64.inputs`: a hash of the patches, `slim.config` and the build
  script, kept beside the kernel (`ferry_kernel_inputs`, tested in
  `tests/versions-test.sh`). `ferry kernel` rebuilds a kernel built from other
  inputs instead of calling it present, `ferry doctor` warns about one, and
  `release/build.sh` refuses to ship one. That guards the kernel against the
  mistake of the stale kubelet v0.4.0 shipped.
- ferry-cri boots pods with `swiotlb=noforce transparent_hugepage=never`.
- `maxPods` is derived from 133 MiB per pod instead of 226: 110 from 32 GiB up
  (was 72 at 32 GiB), 61 at 16 GiB (was 36). A checkout whose kernel predates
  these inputs keeps the 226 figure, since it still pays it.

## Caveats

- **Idle pods.** A pod's own working set comes on top, as before. This moves
  the fixed part only, and the 21 MiB/GiB slope means a pod with a large limit
  still costs more idle than a small one.
- **One machine**, and not the one experiment 13 used (M1 Max, 32 GiB). The
  before figure reproduced within a MiB or two (227 against 225-226).
- **The kernel patch had one measured cost**, cold sequential reads of large
  files (4.9 → 3.0 GB/s median). Since experiment 36 it applies to the init
  disk only, because ferry-cri sets every other disk to 1 MiB.
- **THP off** also takes huge pages from a workload that asks for them with
  `madvise`. This was not measured for any workload.


## Reproduce

```sh
./kernel/build-kernel.sh                  # the kernel, with patches/ and slim.config
(cd ferry-cri && ./build.sh)
cd experiments/32-pod-memory-footprint
./probe-at.sh base probe.sh && ./show.py results/base.json   # guest breakdown
./probe-at.sh cache probe-cache.sh        # who is in the page cache (fincore)
./probe-at.sh vmexec probe-vmexec.sh      # read-ahead against vmexec start
./probe-at.sh seq probe-seq.sh            # read-ahead against sequential reads
./matrix-shape.sh final=../../kernel/vmlinux-arm64       # VM size and vCPUs
./density.sh "20 60"                      # needs build/ferry-cri-before, build/vmlinux-before
./latency.sh 10
./vms.sh detail                           # footprint(1) of a running VM
# against a running `ferry up`:
kubectl apply -f cluster-check.yaml && ./cluster-density.sh 20 after
```

`build/ferry-cri-before` and `build/vmlinux-before` are the runtime and kernel
from before this experiment, copied from a checkout at `d321955`.
