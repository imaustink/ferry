# ferry

Kubernetes on a Mac where **the pod is the virtual machine** and there is no
Linux host anywhere in the system.

The control plane runs as native Mach-O processes on macOS. Each pod is a
lightweight VM on `Virtualization.framework` with its own kernel. There is no
node VM to size, nothing nested, and no shared kernel between pods.

|  | isolation | overhead |
|---|---|---|
| Docker Desktop / colima / kind | one Linux VM, pods share a kernel | a VM you size up front |
| kiac / Orchard | VM per **node**, pods share the node's kernel | 2–4 GB per node, idle or not |
| **ferry** | VM per **pod** — every pod its own kernel | pods only |

Pod semantics fall out of the VM boundary: one VM is one network stack, so
containers in a pod share localhost and IPC by construction. No pause
container, no network namespace plumbing.

## Status

Early, but the load-bearing questions are answered. **[docs/HANDOFF.md](docs/HANDOFF.md)
is the full picture** — architecture, findings, next steps, and the gotchas that
cost time.

- ✅ **Control plane runs natively on macOS.** etcd + kube-apiserver +
  kube-controller-manager + kube-scheduler as darwin/arm64 processes. Serves
  `/version` as `platform: darwin/arm64`, reconciles Deployment → ReplicaSet →
  Pods, issues ServiceAccount tokens.
- ✅ **The kubelet works on macOS** with ~450 lines of platform glue. Drives a
  full pod lifecycle over CRI. See
  [experiments/01-kubelet-cri-surface](experiments/01-kubelet-cri-surface/FINDINGS.md).
- ✅ **The Mac registers as a real Kubernetes node** and runs scheduled
  workloads. `kubectl get nodes` reports `OS-IMAGE: macOS 15.6.1`; a 10-replica
  Deployment reaches 10/10. See
  [experiments/02-node-registration](experiments/02-node-registration/FINDINGS.md).
- ✅ **The VM ceiling is 128, and Kubernetes' default is 110.** One VM per pod
  fits, with 18 to spare. Guests boot to userspace in ~0.12s and VM memory is
  lazily backed — 64 GiB configured cost 1.6 GiB resident. See
  [experiments/03-vm-ceiling](experiments/03-vm-ceiling/FINDINGS.md).
  The ceiling is invariant to devices: 128 bare, 128 with a NIC each, 128 with
  a NIC and a rootfs block device each.
- ✅ **Routable per-pod networking works.** A `VmnetNetwork` allocates an address
  per pod with the Mac as gateway; a real Alpine pod boots in **0.33s**, answers
  ping from the host in **0.34ms**, and reaches another pod directly. No root
  required. See [experiments/04-pod-networking](experiments/04-pod-networking/FINDINGS.md).
- 🔨 **`ferry-cri`** — a CRI implementation in Swift backed by Apple's
  Containerization framework. Not started; it needs the Swift 6.2 toolchain.
  Design sketch in [docs/HANDOFF.md](docs/HANDOFF.md).

## Why this can work

Nothing in the control plane touches the kernel — it is a database and three
programs that watch it. Only the kubelet, kube-proxy, and the workloads need
Linux, and Apple's Containerization framework supplies Linux.

Its `SandboxContext` gRPC API already models what a pod needs: multiple
containers per VM (`CreateProcessRequest.containerID`,
`ContainerStatisticsRequest.container_ids` — *"Empty = all containers"*),
arbitrary mounts, in-guest network configuration, and cgroups v2 via `vminitd`.
One-container-per-VM is the `container` CLI's policy, not a framework limit.

## Layout

```
build-kubelet.sh                     build darwin kubelet from upstream + overlay
patches/kubelet/                     platform implementations, mirroring upstream paths
control-plane/                       PKI + up/down for the native control plane
experiments/01-kubelet-cri-surface/  fake CRI runtime + harness
experiments/02-node-registration/    the Mac as a node, against the real API
experiments/03-vm-ceiling/           how many VMs macOS runs, and how fast
experiments/04-pod-networking/       routable per-pod addressing, host and pod to pod
bin/                                 build output (gitignored)
```

## Try it

```sh
./build-kubelet.sh
(cd experiments/01-kubelet-cri-surface && go build -o ../../bin/fakecri .)
control-plane/up.sh
experiments/02-node-registration/run.sh

export KUBECONFIG=/tmp/ferry/admin.conf
kubectl get nodes -o wide
kubectl create deployment demo --image=nginx:1.27-alpine --replicas=5

experiments/02-node-registration/stop.sh && control-plane/down.sh
```

The runtime is still the fake from experiment 01, so nothing is really executed
— this exercises the control plane and kubelet halves. Pod networking is proven
separately in experiment 04.

## Requirements

- Apple silicon, macOS 26 (Tahoe)
- Go 1.24+
- **Swift 6.2+.** The OS upgrade does not bring the toolchain with it — install
  it explicitly (no sudo needed):
  ```sh
  softwareupdate --install "Command Line Tools for Xcode 26.6-26.6"
  ```

Most of this was developed on macOS 15. What actually needs 26 is routable
per-pod addressing (`VZVmnetNetworkDeviceAttachment`) and the toolchain Apple's
Containerization framework requires to build.
