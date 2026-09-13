<img src="assets/ferry.svg" alt="" width="72">

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
- ✅ **`ferry-cri` runs real pods.** A CRI implementation in Swift on Apple's
  Containerization framework. `kubectl` schedules pods; each becomes its own VM
  with its own routable IP, reachable from the Mac at ~0.4ms. The API server
  advertises the pod gateway, so it is reachable from inside a pod. See
  [experiments/05-real-pods](experiments/05-real-pods/FINDINGS.md).
- 🔨 **Services.** ClusterIPs are not implemented yet; the routing substrate is
  proven and three approaches are compared in [docs/SERVICES.md](docs/SERVICES.md).
- ✅ **Volumes work.** Mounts become virtiofs shares into the pod VM. Projected
  ServiceAccount tokens, ConfigMaps and emptyDir all verified — including a pod
  that authenticates to the API server with its own token.
- ✅ **Resource limits and securityContext work.** The kubelet does not send
  `ContainerConfig.Linux` on darwin, so every pod silently ran unbounded with
  default capabilities; ferry's kubelet derives that code path for darwin.
  A pod with `limits.memory: 300Mi` now gets `memory.max=314572800` in its
  guest cgroup, and `NET_ADMIN` reaches the container.
- ✅ **`kubectl attach` works.** The framework cannot re-open a running
  process's stdio — but ferry owns that stdio, so attach subscribes to the
  writer the container's output already flows through.
- ✅ **`kubectl port-forward` works.** Unusually simple here: pod IPs are
  routable from the Mac, so there is no namespace to enter — the streamer dials
  the pod directly.
- ✅ **Sidecars work.** Containers in a pod share one VM, and therefore one
  network stack: a process in one reaches a listener in another over
  `127.0.0.1`. The hypervisor cannot add a container to a running VM, so the
  boot waits until the kubelet has created them all.
- ✅ **`kubectl exec` works** — stdin, stderr and exit codes included. CRI
  carries exec over SPDY rather than gRPC, so `ferry-streamer` terminates that
  using Kubernetes' own streaming server and hands the request to `ferry-cri`.
- ✅ **Services route inside the pods, with kube-proxy's own rules.**
  `ferry-proxyd` runs kube-proxy's rule generation natively on macOS and renders
  the ruleset; each pod applies it to its own kernel. Traffic goes pod to pod
  and nothing needs root. See [docs/SERVICES.md](docs/SERVICES.md).
- ✅ **Cluster DNS works.** CoreDNS runs as a pod on an address reserved before
  any pod can take it, so the kubelet can be told where DNS lives before DNS
  exists. Pods resolve external names and cluster names.

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
experiments/05-real-pods/            the whole stack, with real VMs per pod
ferry-cri/                           the CRI runtime: one VM per pod
ferry-streamer/                      SPDY streaming for kubectl exec
ferry-proxyd/ (in patches/)          kube-proxy's rule generation, built for darwin
guest/                               nft, bundled with its loader for pods
ferry-proxy/                         host-side ClusterIP routing (fallback)
kernel/                              guest kernel with NAT support
assets/                              the logo
bin/                                 build output (gitignored)
```

## Try it

```sh
./ferry doctor    # check this machine can run ferry
./ferry build     # kubelet, runtime, guest kernel
./ferry up

export KUBECONFIG=~/.ferry/admin.conf
kubectl run demo --image=ghcr.io/linuxcontainers/alpine:3.20 --restart=Never \
  --command -- /bin/sh -c "echo hello from a VM; sleep 3600"

kubectl get pods -o wide          # each pod has its own routable address
kubectl logs demo
ping "$(kubectl get pod demo -o jsonpath='{.status.podIP}')"

./ferry status
./ferry down
```

`ferry doctor` explains what is missing if the machine is not ready — the most
common answer being that a macOS upgrade does not bring the Swift toolchain with
it.

### Limits worth knowing

- **No sidecars.** `Virtualization.framework` cannot hotplug, so a container
  cannot join a pod whose VM is already running. **Init containers do work** —
  each exits before the next is created, so the VM is rebuilt between them and
  shared volumes carry state across. Two containers running *at once* in one pod
  does not work.
- **Services** route inside each pod using kube-proxy's own rules and need no
  privilege on the Mac — build the guest kernel with `ferry kernel` first, or
  ferry falls back to a host proxy that does need root. Conntrack is not
  reconciled, and only TCP has been verified.
- `logs`, `exec`, `port-forward` and `attach` all work. Attach needs the pod to
  set `stdin: true` to accept input, since the stream has to be wired in when
  the container is created.
- **128 pods, shared.** The VM ceiling belongs to the machine, so every other
  VM — Docker Desktop included — takes one of ferry's slots.

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
