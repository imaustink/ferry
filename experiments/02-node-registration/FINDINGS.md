# Experiment 02 — The Mac as a Kubernetes node

**Question.** Experiment 01 proved the kubelet drives a pod lifecycle over CRI
in standalone mode. Does the whole architecture hold together against a real
API server — registration, authn/authz, scheduling, volumes, controllers?

**Method.** Start the native control plane (`control-plane/up.sh`), point the
patched darwin kubelet at it with a client certificate, and drive it entirely
through `kubectl`. The runtime is still experiment 01's fake, so nothing is
actually executed — this tests the kubelet/API-server half.

## Result

```
$ kubectl get nodes -o wide
NAME      STATUS  ROLES   VERSION  INTERNAL-IP    OS-IMAGE       KERNEL-VERSION  CONTAINER-RUNTIME
k5s-mac   Ready   <none>  v1.34.0  192.168.1.29   macOS 15.6.1   24.6.0          k5s-fakecri://0.1.0

$ kubectl get node k5s-mac -o jsonpath='{.status.capacity}'
{"cpu":"16","ephemeral-storage":"0","memory":"128Gi","pods":"110"}

$ kubectl create deployment fleet --image=nginx:1.27-alpine --replicas=10
$ kubectl get deploy fleet
NAME    READY   UP-TO-DATE   AVAILABLE
fleet   10/10   10           10
```

`OS-IMAGE: macOS 15.6.1`, `KERNEL-VERSION: 24.6.0`, `darwin/arm64` — reported
by `cadvisor_darwin.go` from `sysctl`. Capacity is the real machine.

What this exercised end to end:

- **Registration** — kubelet creates its own Node object, authenticating as
  `system:node:k5s-mac` in group `system:nodes` against the Node authorizer.
- **Heartbeats** — Lease objects in `kube-node-lease`, node status updates.
- **Scheduling** — the scheduler binds pods to a macOS node like any other.
- **Volumes** — the projected ServiceAccount volume is assembled on the Mac's
  filesystem with the correct atomic-writer layout, holding a genuine signed
  JWT:
  ```
  .../volumes/kubernetes.io~projected/kube-api-access-XXXXX/..2026_09_12_.../token
  eyJhbGciOiJSUzI1NiIsImtpZCI6IlhRRFNpWnNU...
  ```
- **Controllers** — Deployment → ReplicaSet → 10 pods, all reaching Running.

## New walls

| Failure | Fatal | Resolution |
|---|---|---|
| `MountVolume.SetUp failed: util/mount on this platform is not supported` | pod-fatal | `mount_darwin.go` in `staging/src/k8s.io/mount-utils` |

That is the only one. It is the seventh and, so far, last structural gap.

`mount_darwin.go` serves mount requests from the filesystem rather than the
kernel: `tmpfs` becomes an ordinary directory, `Unmount` removes it, and
anything else is reported as unsupported rather than silently ignored. This is
correct for the target architecture — a pod is a VM, so real mounts happen
inside the guest and the host's job is only to assemble volume contents in a
directory to hand over.

**One real consequence to carry forward:** on Linux, projected ServiceAccount
tokens live on tmpfs and never touch a disk. macOS has no tmpfs, so they land
on an ordinary (FileVault-encrypted) filesystem and are deleted on teardown.

## A bug in the harness, not the kubelet

At 5 replicas, 3 pods hung Pending with:

```
failed to "KillContainer" for "web" ... when killing container for reason ""
```

`fakecri` was ignoring the filter on `ListContainers`/`ListPodSandbox`, so every
pod saw every other pod's containers and tried to kill them. Honouring the
filter fixed it. Worth recording because a real CRI implementation must get
this right: the kubelet uses those listings to decide container ownership, and
an unfiltered answer corrupts its view of the whole node.

## Patch surface after two experiments

| File | Lines |
|---|---|
| `pkg/kubelet/cadvisor/cadvisor_darwin.go` | ~180 |
| `pkg/volume/util/hostutil/hostutil_darwin.go` | ~115 |
| `staging/src/k8s.io/mount-utils/mount_darwin.go` | ~130 |
| `pkg/kubelet/cm/container_manager_darwin.go` | ~15 |
| `pkg/kubelet/container_logs_dir_darwin.go` | ~10 |

~450 lines, five files, plus four build-tag widenings.

## Follow-up: the residual issues, resolved

All four were closed after the initial run.

| Issue | Fix | Result |
|---|---|---|
| eviction manager: root cgroup stats | `ContainerInfoV2("/")` synthesises root memory from `hw.memsize` and `vm.page_free_count` | errors gone; eviction now works |
| static pod file watching unsupported | `file_linux.go` is pure fsnotify with no Linux API — widened its build tag to `linux \|\| darwin` | errors gone, no new code |
| CSI plugin prober wants `/usr/libexec/kubernetes` | `volumePluginDir` in KubeletConfiguration | config only, no patch |
| `ephemeral-storage` reports 0 | node capacity comes from `ContainerManager.GetCapacity`, which the stub answers as zero. The darwin manager now wraps the stub and reports real `RootFsInfo` capacity | `971350180Ki` |

Making eviction work had an immediate and correct consequence:

```
MemoryPressure=False  DiskPressure=True  PIDPressure=False  Ready=True
node.kubernetes.io/disk-pressure=NoSchedule
```

The host disk was at 97%, below the default `nodefs.available<10%` threshold,
so the eviction manager tainted the node and evicted all 10 pods. That is
correct Kubernetes behaviour driven by real macOS statistics — a whole kubelet
subsystem working, not a bug. Worth knowing when testing on a full disk.

One known gap remains, and it is structural rather than a defect:

```
"Eviction manager: failed to construct signal"
  err="system container \"pods\" not found in metrics"
  signal="allocatableMemory.available"
```

The `allocatableMemory.available` signal is derived from the `pods` cgroup,
which genuinely does not exist on this platform. Node-level memory and disk
signals work; this one cannot without a host cgroup tree.

## Still outstanding

- control plane advertises the LAN IP; must become the vmnet gateway

## Reproduce

```sh
control-plane/up.sh
experiments/02-node-registration/run.sh
export KUBECONFIG=/tmp/k5s/admin.conf
kubectl get nodes -o wide
kubectl create deployment fleet --image=nginx:1.27-alpine --replicas=10
experiments/02-node-registration/stop.sh && control-plane/down.sh
```
