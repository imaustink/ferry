# Ferry — state of play

Everything needed to pick this up cold. Written just before the macOS 26
upgrade, with the control plane and kubelet working and the runtime not yet
started.

---

## The idea

**Kubernetes on a Mac where the pod *is* the virtual machine, and there is no
Linux host anywhere in the system.**

The control plane runs as native Mach-O processes. Each pod is a lightweight VM
on `Virtualization.framework` with its own kernel. There is no node VM to size,
nothing nested, and no shared kernel between pods.

|  | isolation | overhead |
|---|---|---|
| Docker Desktop / colima / kind | one Linux VM, pods share a kernel | a VM you size up front |
| kiac / Orchard | VM per **node**, pods share the node's kernel | 2–4 GB per node, idle or not |
| **ferry** | VM per **pod** — every pod its own kernel | pods only |

The load-bearing insight: **pod semantics fall out of the VM boundary.** One VM
is one network stack, so containers in a pod share localhost and IPC by
construction. No pause container, no netns plumbing. Cleaner than Linux.

### Why the pieces land where they do

Nothing in the control plane touches the kernel — it is a database and three
programs that watch it. Only the kubelet, kube-proxy, and workloads need Linux.
So the control plane runs natively and costs nothing, and Linux appears only
inside per-pod VMs where it is genuinely needed.

This is also the managed-cloud topology: EKS/GKE/AKS all show workers only, with
the control plane off-cluster and not a Node object. Ferry has **zero
control-plane nodes** for the same reason. That is normal, not exotic.

---

## What is proven

### Control plane runs natively on macOS

etcd + kube-apiserver + kube-controller-manager + kube-scheduler as
darwin/arm64 processes. `/version` reports `platform: darwin/arm64`. Reconciles
Deployment → ReplicaSet → Pods, issues ServiceAccount tokens.

### The kubelet works on macOS — ~450 lines of platform glue

| File | Lines | Purpose |
|---|---|---|
| `pkg/kubelet/cadvisor/cadvisor_darwin.go` | ~250 | machine facts from sysctl, fs from statfs, root memory for eviction |
| `staging/src/k8s.io/mount-utils/mount_darwin.go` | ~130 | mounts served from the filesystem, not the kernel |
| `pkg/volume/util/hostutil/hostutil_darwin.go` | ~115 | stat-based file queries |
| `pkg/kubelet/cm/container_manager_darwin.go` | ~80 | upstream stub + real node capacity |
| `pkg/kubelet/container_logs_dir_darwin.go` | ~10 | overridable container log root |

Plus five build-tag edits, applied by `build-kubelet.sh`. **No upstream logic is
reimplemented.** Every gap was a missing platform implementation behind an
interface that already existed.

### The Mac registers as a node and runs workloads

```
NAME        STATUS  ROLES   VERSION   OS-IMAGE       KERNEL-VERSION  CONTAINER-RUNTIME
ferry-mac   Ready   <none>  v1.34.0   macOS 15.6.1   24.6.0          ferry-fakecri://0.1.0

capacity: {"cpu":"16","ephemeral-storage":"971350180Ki","memory":"128Gi","pods":"110"}
```

Registration, Node-authorizer authz, leases, scheduling, projected
ServiceAccount volumes (real signed JWTs on disk), eviction, and the full
controller chain all work. A 10-replica Deployment reaches 10/10.

### The hypervisor supports the density

| VM shape | ceiling | mean start |
|---|---|---|
| bare | 128 | 0.091s |
| + NIC | **128** | 0.063s |
| + NIC + rootfs block device | **128** | 0.063s |

- **128 concurrent VMs**, a hard cap in `Virtualization.framework` — identical
  at 128 MiB and 512 MiB per VM, so it is a VM-count limit, not resource
  exhaustion. Confirmed on both macOS 15.6.1 and 26.6.2. **The kubelet's default
  `maxPods` is 110**, so the ceiling clears the density Kubernetes already
  expects, with 18 to spare.
- **The cap is system-wide.** Docker Desktop running costs a slot (127 instead
  of 128). Every other VM on the Mac spends one of ferry's pod slots, so the
  usable ceiling is `128 − (other VMs)`. Ferry should count live VMs and report
  real remaining capacity rather than letting pods fail at admission.
- **0.12s** guest boot to userspace, cold. No degradation at VM 128.
- **VM memory is lazily backed** — 128 VMs × 512 MiB (64 GiB configured) cost
  **1.6 GiB** resident. Density is bounded by the VM cap, not by summing pod
  limits.

---

## Repo layout

```
build-kubelet.sh                     clone upstream + apply overlay + build
patches/kubelet/                     darwin implementations, mirroring upstream paths
control-plane/
  pki.sh                             CA, serving, client, front-proxy, SA certs
  fetch-binaries.sh                  darwin/arm64 control plane + etcd
  up.sh / down.sh                    start/stop the four processes
experiments/
  01-kubelet-cri-surface/            fake CRI runtime + harness
  02-node-registration/              the Mac as a node, against the real API
  03-vm-ceiling/                     how many VMs macOS runs, and how fast
docs/HANDOFF.md                      this file
bin/                                 build output (gitignored)
```

Patches are **whole files in an overlay**, not diffs — diffs against a tree that
size rot too fast. Build-tag edits are `sed` in `build-kubelet.sh`.

## Running what exists

```sh
./build-kubelet.sh
(cd experiments/01-kubelet-cri-surface && go build -o ../../bin/fakecri .)

control-plane/up.sh
experiments/02-node-registration/run.sh
export KUBECONFIG=/tmp/ferry/admin.conf
kubectl get nodes -o wide

experiments/02-node-registration/stop.sh && control-plane/down.sh
```

VM ceiling probe:

```sh
cd experiments/03-vm-ceiling
./build.sh                                    # fetches kernel, builds, ad-hoc signs
./build/vmceiling --max 256 --memory 128
./build/vmceiling --max 140 --network --disk
```

---

## Next: `ferry-cri`

Replace `fakecri` with a real CRI implementation backed by Apple's
Containerization framework. **Write it in Swift**, and build it on `LinuxPod`.

### The framework already has pods

This was the big discovery after the macOS 26 upgrade.
`Sources/Containerization/LinuxPod.swift` is a first-class pod abstraction, and
its shape is startlingly close to a Kubernetes PodSpec:

```swift
public final class LinuxPod: Sendable {
    public struct Configuration {
        public var cpus: Int
        public var memoryInBytes: UInt64
        public var interfaces: [any Interface]
        public var shareProcessNamespace: Bool     // = spec.shareProcessNamespace
        public var hostname: String?
        public var dns: DNS?
        public var hosts: Hosts?
        public var volumes: [PodVolume]
    }
    public struct ContainerConfiguration {
        public var process: LinuxProcessConfiguration
        public var cpus: Int?                      // per-container limits
        public var memoryInBytes: UInt64?
        public var sysctl: [String: String]
        public var mounts: [Mount]
        public var maskedPaths: [String]           // OCI runtime spec
        public var readonlyPaths: [String]
    }
}
```

`addContainer` hotplugs into a **running** pod, which is exactly CRI's ordering
(`RunPodSandbox`, then `CreateContainer` later). The mapping is close to 1:1:

| CRI | LinuxPod |
|---|---|
| `RunPodSandbox` | `LinuxPod(id:vmm:configuration:)` + `create()` |
| `CreateContainer` | `addContainer(id, rootfs:configuration:)` |
| `StartContainer` | `startContainer(_:)` |
| `StopContainer` | `stopContainer(_:)` |
| `ListContainers` | `listContainers()` |
| `ContainerStats` | `statistics(containerIDs:categories:)` |
| `ExecSync` / `Exec` | `execInContainer(...)` |
| container exit | `waitContainer(_:timeoutInSeconds:)` → `ExitStatus` |
| TTY resize | `resizeContainer(_:to:)` |
| `StopPodSandbox` | `stop()` |

Apple's own `Sources/Integration/PodTests.swift` is a working example of a
multi-container pod: one VM, one rootfs per container, started independently.

### Networking is solved too

`Sources/Containerization/VmnetNetwork.swift`, gated `@available(macOS 26.0, *)`,
is the piece that was missing on macOS 15:

```swift
public struct VmnetNetwork: Network {
    public let subnet: CIDRv4
    public var ipv4Gateway: IPv4Address
    public mutating func createInterface(_ id: String) throws -> Interface?
    public mutating func releaseInterface(_ id: String) throws
}
```

That is **IPAM** — per-pod address allocation from a routable subnet, with the
Mac as the gateway, attached via `VZVmnetNetworkDeviceAttachment`. So:

- `RunPodSandbox` → `createInterface(podID)` → pass the result to
  `Configuration.interfaces`
- `RemovePodSandbox` → `releaseInterface(podID)`
- pods are reachable from the Mac and from each other; the API server is
  reachable at the gateway address

`Interface` is a pure value type describing guest-side IP config, so **ferry
chooses each pod's address** — which is precisely a CNI's job.

### Volumes

`PodVolume.Source` is `.nbd`, `.diskImage`, or **`.tmpfs`**. The tmpfs case
closes a gap recorded earlier: on Linux, projected ServiceAccount tokens live on
tmpfs and never touch a disk. A pod-VM tmpfs restores exactly that property,
inside the guest.

### Images

`ImageStore` pulls OCI images; `ContainerizationEXT4` converts them to ext4
block devices used as container rootfs. `initBlock` builds the init filesystem.
No containerd, no snapshotters.

### Carry-over warning

**A real CRI must honour the filters on `ListContainers` and `ListPodSandbox`.**
`fakecri` ignored them, every pod believed it owned every container, and the
kubelet tried to kill them. The kubelet derives container ownership from those
listings.

## First things after the upgrade

1. ~~`swift --version` — needs ≥ 6.2.~~ **Done.** The OS upgrade does not bring
   the toolchain; install it explicitly:
   `softwareupdate --install "Command Line Tools for Xcode 26.6-26.6"`.
   That yields Swift 6.3.3, and needs no sudo.
2. ~~Build Apple's Containerization framework.~~ In progress.
3. ~~Re-run `experiments/03-vm-ceiling` on macOS 26.~~ **Done** — 128 holds, and
   the cap turned out to be system-wide.
4. **Measure vmnet properly.** The remaining unknown: routable per-pod
   addressing. `VZNATNetworkDeviceAttachment` proved capacity, but each pod needs
   a stable address reachable from the host and from other pods.
5. Change `ADVERTISE` in `control-plane/up.sh` from the LAN IP to the vmnet
   gateway (`192.168.64.1`). It is already in the cert SANs from `pki.sh`.
6. Start `ferry-cri`.

---

## Gotchas — the things that cost time

- **macOS caps unix socket paths at ~104 bytes.** The kubelet builds its
  podresources socket under `--root-dir`, so run dirs live under `/tmp`, not in
  the repo.
- **`--advertise-address` may not be loopback.** The endpoint reconciler writes
  it into the `kubernetes` Endpoints that every in-cluster client resolves
  `10.96.0.1` to. Must become the vmnet gateway.
- **Default eviction thresholds are wrong for a laptop.** `imagefs.available<15%`
  on a 926 GB disk means holding 139 GB idle or the node taints itself
  NoSchedule. Both run scripts set `evictionHard` to 5%.
- **`/var/log/containers` and `/usr/libexec/kubernetes`** are not writable
  without root (the latter not even with it, under SIP). Use
  `FERRY_CONTAINER_LOGS_DIR` and `volumePluginDir`.
- **The kubelet warns it wants uid 0** and runs fine as a user for development.
  Production would be a launchd daemon as root.
- **Control plane binaries are unofficial.** Upstream publishes no darwin build
  of the control plane, only kubectl. `fetch-binaries.sh` pulls from
  `kwok-ci/k8s`, explicitly dev/test only. Building from kubernetes source with
  `KUBE_BUILD_PLATFORMS=darwin/arm64` is the eventual fix.
- **`ServiceAccount tokens land on disk, not tmpfs.** macOS has no tmpfs. They
  are on a FileVault-encrypted volume and removed on teardown, but this is a
  real difference from Linux worth remembering.
- **The VM probe needs `com.apple.security.virtualization`.** `build.sh` ad-hoc
  signs it; without the entitlement the framework refuses to create a VM.

## Known gaps

- `allocatableMemory.available` eviction signal cannot be constructed — it
  derives from the `pods` cgroup, which does not exist here. Node-level memory
  and disk signals work.
- `kube-proxy` does not run on the Mac, so ClusterIPs (`10.96.0.0/16`) are not
  reachable from the host. `kubectl` is unaffected. Options later: host routes
  to a pod VM, `kubectl port-forward`, or a small userspace proxy.
- Host routes to pod CIDRs are not managed yet. Watching Nodes and running
  `route add/delete` per PodCIDR would make pod IPs directly reachable from
  macOS — something Docker Desktop cannot do.
