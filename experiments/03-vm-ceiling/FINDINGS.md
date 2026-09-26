# Experiment 03: How many VMs, and how fast?

**Question.** With one VM per pod, two numbers bound the whole design: the
number of virtual machines macOS will run at once is the pod limit for the
node, and VM boot time is pod start latency. Neither was known.

**Method.** A Swift probe against `Virtualization.framework` directly, with no
Apple Containerization and no `container` CLI, so the answer is a property of
the OS rather than of any container tool. Each VM boots the kata-containers
Linux 6.12.28 arm64 kernel with a 1.6 MiB initramfs whose `/init` is a static
Go binary that prints a marker and sleeps forever. The probe starts VMs one at
a time and keeps them running until one fails.

Run on macOS 15.6.1 and re-run on macOS 26.6.2 (Tahoe), M4 Max, 128 GiB.

## Results

### The ceiling is exactly 128

```
concurrent VMs reached : 128
stopped because        : VM 129 failed to start: Internal Virtualization error.
```

Identical at 128 MiB per VM (16 GiB configured) and at 512 MiB per VM (64 GiB
configured). Start latency was flat right up to the limit, and memory pressure
never moved. This is a hard cap on VM count in Virtualization.framework, not
resource exhaustion.

### Kubernetes' own default is 110

The kubelet's default `maxPods` is 110, which is exactly what the Mac reported
as its capacity in experiment 02:

```
{"cpu":"16","ephemeral-storage":"0","memory":"128Gi","pods":"110"}
```

The hypervisor ceiling sits above the Kubernetes default with 18 to spare.
One VM per pod is viable at the density Kubernetes already expects from a node.

### The cap is system-wide, not per-process

Re-running on macOS 26.6.2 first gave 127, one short of the figure measured on
macOS 15. The missing slot was Docker Desktop, which keeps a VM running
(`com.docker.virtualization`, 16 CPU / 16 GiB) whenever it is open:

| system state | ceiling |
|---|---|
| Docker Desktop running | 127 |
| Docker Desktop quit | **128** |

So the limit belongs to the machine, not to the process asking. Every other
virtual machine on the Mac (Docker Desktop, UTM, Parallels, another ferry)
spends one of ferry's pod slots.

Two consequences for the design:

- The usable pod ceiling is `128 − (other VMs running)`. Against a default
  `maxPods` of 110 that leaves 18 slots of headroom, which is comfortable but is
  a *shared* budget rather than ferry's alone.
- Ferry should report this rather than let pods fail mysteriously at admission.
  It should count live VMs and reflect the real remaining capacity, so the
  scheduler stops placing pods that cannot start.

The number itself is stable across OS versions: 128 on macOS 15.6.1 and 128 on
macOS 26.6.2.

### Devices do not move the ceiling

Every pod needs a network interface and a root filesystem, and either could
have been scarcer than VMs. Neither is:

| VM shape | ceiling | mean start |
|---|---|---|
| bare | 128 | 0.091s |
| + NIC (`VZNATNetworkDeviceAttachment`) | **128** | 0.063s |
| + NIC + read-only rootfs block device | **128** | 0.063s |

The cap is on virtual machines, not on the devices attached to them.

This also corrects an earlier assumption in the design work, that the vmnet
question needed macOS 26. It does not. `VZNATNetworkDeviceAttachment` has
existed since macOS 11, and answers "can 128 VMs each hold an interface" today.
What does need macOS 26 is *routable per-pod addressing*, meaning multiple
networks and stable per-container IPs. That is an addressing question, not a
capacity one.

### Boot to userspace: ~0.12s

```
guest userspace        : 0.12s (first VM, cold)
start() latency        : min 0.059s  mean 0.091s  max 0.130s
```

Kernel plus init, cold, to the marker printed by PID 1. `start()` latency did
not degrade as VMs accumulated. The 128th started as fast as the first.

### VM memory is lazily backed

128 VMs configured with 512 MiB each (64 GiB), against measured host memory:

| | free pages | pressure |
|---|---|---|
| baseline | 2,222,330 | 96% free |
| 128 VMs running | 1,812,358 | 96% free |

409,972 pages ≈ 1.6 GiB actually consumed for 64 GiB configured. Guests pay for
what they touch.

This settles a question from the design discussion. VM-per-pod does *not* mean
summing every pod's memory limit against physical RAM. The 128-VM cap bounds
density, not memory.

## What this means for ferry

The thesis survives, with room to spare:

- 128 pods per Mac, against a Kubernetes default of 110
- ~0.12s of hypervisor and kernel boot in the pod start path
- memory overcommit works, so per-pod VM sizing can be generous

## Caveats: do not over-read these numbers

- **The guest is trivial.** A 1.6 MiB initramfs and a sleeping init. A real pod
  carries an OCI rootfs, virtiofs mounts, a network interface, and a workload.
  0.12s is a floor, not a prediction.
- **Devices are attached but unused.** The guest never configures the NIC or
  mounts the block device. This measures how many devices can *exist*, not the
  cost of traffic or I/O through them.
- **No virtiofs share.** Volume sharing into the guest is still unmeasured.
- **Routable per-pod addressing is still open.** NAT attachment proves capacity,
  but it does not give each pod a stable address reachable from the host and
  from other pods. That is the macOS 26 question.
- **Measured on one machine.** 128 held on both macOS 15.6.1 and 26.6.2, but
  this is one M4 Max. The cap may scale with hardware.

## Reproduce

```sh
./build.sh                                  # guest init, initramfs, signed probe
./build/vmceiling --max 256 --memory 128    # find the ceiling
./build/vmceiling --max 128 --memory 512 --hold 30   # hold, to sample host memory
./build/vmceiling --max 140 --network --disk         # realistic pod device shape
```

`build.sh` ad-hoc signs the probe with `com.apple.security.virtualization`.
Without that entitlement the framework refuses to create a VM.

`fetch-kernel.sh` downloads the kernel from the kata-containers 3.17.0 release,
the same one Apple's Containerization framework uses by default.
