# Experiment 14 — Can a pod VM be resized while it is running?

**Question.** Ferry sizes a pod's VM when it boots and never revisits it, which
makes `--pod-memory-mib` a guess applied to every pod on the node. Experiment 13
put a price on the boundary — 225 MiB per pod — and raised the obvious follow-up:
if a running VM could be grown or shrunk, the guess would stop mattering.

**Method.** `Virtualization.framework` has a memory balloon. This boots a VM
with one, has the guest dirty a large block and release it, then asks for the
memory back and watches three things at once: what the guest thinks it has,
what the host has charged the VM process, and what the machine has free.

Virtualization.framework alone — no Containerization, no `ferry-cri` — and
built with `swiftc` rather than SwiftPM, so it does not depend on the package
manager half of the toolchain being in working order.

Run on macOS 26.6.2, Apple M1 Max, 10 cores, 32 GiB, against ferry's own guest kernel.

## Results

### Memory can be taken from a running guest, immediately

A 4096 MiB VM, guest dirties 2048 MiB and releases it, then the host asks for
512 MiB:

```
                      footprint    rss     host free   guest total  guest free
after touch+release        2253   2313         10840          3924        3767
-- requested 512 MiB, device reports 512 MiB --
shrinking                  2253   2313         10809          3924         222
shrinking                  2253   2313         10826          3924         239
-- restored to 4096 MiB --
restored                   2253   2313         10818          3924        3853
```

The guest goes from 3767 MiB free to 222 within one sample, and back on
restore. **The balloon works, both directions, in seconds.** The guest binds
the driver — `virtio1 device=0x0005 driver=virtio_balloon` — and ferry's kernel
already enables it, since it is built from Apple's own configuration.

### But the host does not get the memory back

Across the same run, `phys_footprint` sat at 2253 MiB and RSS at 2313 MiB,
before the request, during it, and after. Machine-wide free memory moved by
less than 1% — noise, against the 3.5 GiB the guest had just given up.

Darwin's `MADV_FREE` keeps pages resident until something needs them, so this
could have been a reclaim that had simply not been billed yet. It was not:
allocating and touching 8192 MiB on the host, while the balloon was inflated,
moved the VM's footprint by **0 MiB**. The host found its 8 GiB elsewhere.

**So the balloon is a cap, not a reclaim.** It changes what the guest believes
it may use. It does not hand memory back to macOS — at least not on a host with
memory to spare, which is the only condition tested here.

### The configured size is a hard ceiling

`targetVirtualMachineMemorySize` is documented to range from
`minimumAllowedMemorySize` to `VZVirtualMachineConfiguration.memorySize`. A VM
can be shrunk below the size it booted with and grown back up to it, and no
further. There is no runtime equivalent for CPU: `VZVirtualMachine` exposes no
writable `cpuCount` or `memorySize`, and `memoryBalloonDevices` is the only
mutable knob on a running machine.

Which makes the useful direction the opposite of the obvious one. Since
untouched guest memory is nearly free — experiment 03 measured 64 GiB
configured costing 1.6 GiB resident, and a 4096 MiB pod VM that allocates
1024 MiB costs 1434 MiB, not 4096 — a pod VM can be **configured generously and
ballooned down to what the pod is actually allowed**, leaving room to grow later
without a restart.

### Nothing in the stack asks for one

Containerization builds its VM configuration in
`VZVirtualMachineInstance.swift:413`, setting `cpuCount` and `memorySize` and
attaching no balloon. Ferry inherits that, so today no pod VM has the device at
all. Adding it is a change to how the configuration is built, not new
capability.

### Why this matters: a pod cannot have the memory it asked for

Ferry sizes every pod VM at `config.defaultMemoryBytes`
(`PodRuntime.swift:508`) and sets the container's cgroup from the pod's own
limit (`PodRuntime.swift:1052`). The two do not talk to each other. A pod
declaring `limits.memory: 2Gi`, allocating 1 GiB, on the default 512 MiB VM:

```
  pod-00.log: MemoryError
```

The same pod, same limit, on a VM configured at 4096 MiB:

```
  pod-00.log: ALLOCATED 1024 MiB
  VM footprint  1434 MiB          <- what it touched, not what it was given
```

The cgroup permits 2 GiB; the machine has 512 MiB. The pod dies well inside its
own limit, and the failure is a guest OOM rather than anything Kubernetes can
explain. The code comment at `PodRuntime.swift:405` calls right-sizing "a
worthwhile refinement, not a correctness issue" — on this evidence it is closer
to the latter.

## What this means for ferry

- **Size the pod VM from the pod's own spec.** The aggregate of its containers'
  limits, plus headroom for the guest kernel, instead of one flag for every pod
  on the node. This is the fix for the OOM above and it needs no balloon.
- **Configure generously, balloon down.** Lazily-backed memory means a ceiling
  well above the limit costs nothing until touched, and the balloon enforces the
  limit at the machine level rather than only in a cgroup.
- **In-place pod resize becomes possible.** Kubernetes can change a running
  pod's limits through the `resize` subresource; with a ceiling and a balloon,
  ferry could follow that without restarting the pod — up to the ceiling.
- **Do not expect to reclaim idle pods' memory.** The measurement says the host
  keeps what a guest has touched. Experiment 13's 225 MiB per pod, and the image
  cache duplicated per container, stay paid for as long as the pod lives.

### An unverified lead worth following

`VZUSBController` gained runtime `attachDevice:` / `detachDevice:` in macOS 15,
and `VZUSBMassStorageDevice` exists. If a container rootfs can arrive as a USB
mass storage device, two of ferry's hard limits move at once: containers could
join a pod whose VM is already running, and the 22-block-devices-per-VM ceiling
from experiment 13 would no longer bound a shared kernel.

The blocker is the guest, not the host: Apple's kernel configuration has
`# CONFIG_USB_SUPPORT is not set`. Ferry already builds its own kernel to get
NAT, so testing this is a config change and a probe, not a redesign.

## Caveats

- **Reclaim was tested on a host with memory to spare.** 8 GiB of pressure
  against ~10 GiB free did not move the VM's footprint, but that is not the same
  as proving macOS will never reclaim ballooned pages. Pushing a machine with
  other work on it into real pressure was out of scope.
- **One guest, one kernel.** Ferry's kernel, built from Apple's configuration.
  A guest without `CONFIG_VIRTIO_BALLOON` would show the same inert result for
  an entirely different reason — which is why the probe reports the guest's
  bound drivers before drawing any conclusion.
- **The guest here is an initramfs**, not a pod. It measures the device, not
  what a real workload's page cache does under a balloon.

## Reproduce

```sh
./build.sh
./build/balloon --kernel ../../kernel/vmlinux-arm64 \
    --memory 4096 --touch 2048 --target 512 --settle 8
./build/balloon --kernel ../../kernel/vmlinux-arm64 \
    --memory 4096 --touch 2048 --target 512 --pressure 8192   # does the host take it back
```

The pod-cannot-have-its-limit demonstration uses experiment 13's harness:

```sh
cd ../13-shared-kernel-cost
./runtime.sh start                                   # 512 MiB pod VMs
./build/shkcost -count 1 -workload alloc -image docker.io/library/python:3.12 \
    -limit-mib 2048 -alloc-mib 1024 -state shk-cri-state
POD_MEMORY_MIB=4096 ./runtime.sh start               # and again, with room
```
