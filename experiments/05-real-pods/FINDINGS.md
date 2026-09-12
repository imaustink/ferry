# Experiment 05 — Real pods, one VM each

**Question.** Everything up to here used a fake runtime. Does the whole stack
work with `ferry-cri` in place: native control plane, patched darwin kubelet,
and a real virtual machine per pod?

**Method.** `run.sh` starts `ferry-cri`, then the control plane, then the
kubelet pointed at `ferry-cri`. Pods are created through `kubectl` and probed
from the host.

## Result

```
$ kubectl get nodes -o wide
NAME        STATUS  VERSION  OS-IMAGE      CONTAINER-RUNTIME
ferry-mac   Ready   v1.34.0  macOS 26.6.2  ferry://0.1.0

$ kubectl create deployment fleet --image=alpine:3.20 --replicas=3
$ kubectl get pods -o wide
fleet-5457b9889d-7m2lf   1/1   Running   192.168.77.3   ferry-mac
fleet-5457b9889d-gzlvq   1/1   Running   192.168.77.4   ferry-mac
fleet-5457b9889d-wn95s   1/1   Running   192.168.77.2   ferry-mac
real                     1/1   Running   192.168.77.5   ferry-mac

$ ping <pod ip>
3 packets transmitted, 3 packets received, 0.0% packet loss
round-trip min/avg/max = 0.441/0.627/0.755 ms

$ pgrep -fl com.apple.Virtualization.VirtualMachine
  ... one process per pod
```

Kubernetes scheduling pods onto a Mac, where each pod is a hypervisor-isolated
virtual machine with its own kernel and its own routable address, and no Linux
host exists anywhere in the system.

### The API server is reachable from inside a pod

The API server now advertises the pod network gateway rather than the LAN
address:

```
$ kubectl get endpoints kubernetes
192.168.77.1:6443

$ kubectl run reach --restart=Never --command -- /bin/ping -c 3 192.168.77.1
reach   Succeeded   exit code: 0
```

That is the address every in-cluster client reaches when it resolves
`10.96.0.1`, so this is the precondition for Services and for any workload that
talks to the API.

## What the runtime does

| CRI | implementation |
|---|---|
| `RunPodSandbox` | allocate an address, construct a `LinuxPod` (VM not yet booted) |
| `CreateContainer` | clone the image's ext4 rootfs, `addContainer` |
| `StartContainer` | boot the VM on first use, then `startContainer` |
| `StopContainer` / `StopPodSandbox` | `stopContainer` / `pod.stop()` |
| `RemovePodSandbox` | release the address |
| `ListContainers` / `ListPodSandbox` | **filters honoured** |
| `PullImage` | `ImageStore.pull` + `EXT4Unpacker` to a block device |

## Four things that cost time, and what they mean

### Virtualization.framework cannot hotplug

```
Error: unsupported: "hotplug not supported"
```

`LinuxPod.addContainer` hotplugs into a running VM — but only where the VMM
supports it, which cloud-hypervisor does and `Virtualization.framework` does
not. CRI's ordering is sandbox first, containers afterwards, so a VM created at
`RunPodSandbox` can never accept them.

The fix is to boot the VM lazily on the first `StartContainer`, with every
container added beforehand. **This is a real constraint, not just a workaround:
on this hypervisor a pod's container set must be complete before it starts.**
Single-container pods work. Multi-container pods, and init containers — which
the kubelet creates and starts one at a time — cannot work this way. Options are
to buffer the whole pod's containers before booting (needs the kubelet to be
told the sandbox is not ready yet), or to accept the limitation on macOS.

### vmnet networks leak permanently

A subnet stays claimed after the process that created it is gone, and does not
come back:

```
192.168.66.1/24: HELD       <- used across several runs, never released
192.168.77.1/24: available
192.168.88.1/24: available
```

Still held after 70 seconds with no process holding it and no VMs running.
`ferry-cri` now walks a candidate list and publishes the gateway it actually
obtained, which `run.sh` feeds to the control plane so the API server advertises
the right address. Graceful shutdown on SIGTERM reduces the leak rate but does
not eliminate it.

### The kubelet needs image id *and* size

```
Error: Id or size of image "..." is not set   -> ImageInspectError
```

Both must be non-zero or the pod never starts. Size comes from the unpacked
rootfs, which is what actually occupies disk here.

### The kubelet passes image IDs, not references

`CreateContainer` receives the image *ID* the kubelet resolved, not the
reference `PullImage` was called with. The rootfs cache is keyed by both.

## Known gaps

- **Mounts are ignored.** `ContainerConfig.mounts` is not implemented, so
  projected ServiceAccount tokens, ConfigMaps and Secrets do not reach the pod.
  `LinuxPod.Configuration.volumes` with `PodVolume.Source.tmpfs` is the intended
  home for these, and would put SA tokens on tmpfs inside the guest — closer to
  Linux behaviour than the host-disk projection in experiment 02.
- **No `Exec` / `Attach` / `PortForward` / logs.** `LinuxPod.execInContainer`
  exists; wiring it to CRI's streaming endpoints is not done.
- **No container stats.** Reported empty rather than invented, so the eviction
  manager is not fed fabricated numbers.
- **No Services.** See below.

## Reproduce

```sh
../03-vm-ceiling/fetch-kernel.sh
(cd ../../ferry-cri && ./build.sh)
./run.sh
export KUBECONFIG=/tmp/ferry/admin.conf
kubectl run real --image=ghcr.io/linuxcontainers/alpine:3.20 --restart=Never \
  --command -- /bin/sh -c "sleep 3600"
./stop.sh
```
