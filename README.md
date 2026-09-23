<img src="assets/ferry.svg" alt="" width="72">

# ferry

Kubernetes on a Mac with **nothing to size and nothing to wait for**.

There is no Linux VM to allocate memory to before you start, no machine to keep
running between sessions, and no boot to sit through. A pod is a virtual machine
that starts in **a third of a second**, and the control plane is native Mach-O
processes on macOS — so `ferry up` is a few processes starting, not a VM coming
up.

|  | what you size up front | what it costs idle |
|---|---|---|
| Docker Desktop / colima / kind | a Linux VM: memory and CPUs, before the first pod | the whole VM, used or not |
| kiac / Orchard | a node VM, per node | 2–4 GB per node, idle or not |
| **ferry** | nothing | nothing — pods pay for what they touch |

The last column is measured, not aspirational. 128 pod VMs configured with
512 MiB each — 64 GiB asked for — consumed **1.6 GiB** of host memory, because
guests are lazily backed and pay for the pages they actually touch. Sizing is a
guess you make before you know the answer, and this removes the guess: ask for
what the workload says it wants, and the Mac spends what the workload uses.

**Startup, measured:** the hypervisor starts a VM in 0.06–0.09s and the guest
reaches userspace in ~0.12s, so a real Alpine pod is up in **0.33s** and answers
ping from the Mac in 0.34ms. The 128th VM starts as fast as the first. Nothing
is nested, and there is no node VM in the path.

### Against kind and minikube, on one Mac

Every stack on **Kubernetes v1.37.0**, one after another, each from a machine
with the others shut down — and with Docker Desktop stopped for ferry's runs,
because ferry does not use it and leaving 15.6 GiB of idle VM on the machine
is not the baseline ferry actually has.

| | ferry | ferry `relaxed` | mode 2 | mode 2 `relaxed` | kind | minikube |
|:--|--:|--:|--:|--:|--:|--:|
| a pod is | its own VM | its own VM | a container | a container | a container | a container |
| needs Docker Desktop | **no** | **no** | **no** | **no** | yes | yes |
| writes survive power loss | **yes** | no | **yes** | no | no | no |
| create a cluster | 12.4 s | **11.4 s** | 25.7 s | 19.9 s | 25.8 s | 29.4 s |
| delete it | 0.35 s | 0.35 s | 0.49 s | **0.43 s** | 0.45 s | 13.5 s |
| start one pod | 0.46 s | **0.40 s** | 0.57 s | 0.52 s | 0.56 s | 0.60 s |
| start 10 | 1.70 s | 0.63 s | 0.85 s | **0.60 s** | 0.67 s | 1.09 s |
| start 20 | 3.39 s | 3.27 s | 1.19 s | **0.77 s** | 0.89 s | 1.99 s |
| idle memory | **432 MiB** | **436 MiB** | 1,196 MiB | 1,189 MiB | 4,148 MiB | 3,632 MiB |
| ↳ of that, Docker before any cluster | **0** | **0** | **0** | **0** | 1,685 MiB | 1,679 MiB |
| idle CPU | **2.7%** | **2.6%** | 8.3% | 6.8% | 29.4% | 27.8% |
| per pod | 240 MiB | 239 MiB | **14 MiB** | **14 MiB** | 20 MiB | 20 MiB |

`relaxed` is `ferry up --durability relaxed`, explained below. The four ferry
columns are two choices, not four products: a pod is either its own VM or a
container on a shared one, and writes either reach the disk before they are
acknowledged or they do not.

**Relaxed buys mode 2 a great deal and mode 1 almost nothing.** A 20-pod
burst goes 1.19 s to 0.77 s on mode 2 and 3.39 s to 3.27 s on mode 1. That is
the honest shape of it: mode 1's pod start is a virtual machine booting, and
no disk barrier was ever the thing holding it up. If you want the fast numbers
you want mode 2, and if you want one kernel per pod you are paying for the
kernel, not for `fsync`.

CPU is percent of one core over a 60-second window with the cluster up and
nothing scheduled. This Mac has sixteen.

**"Create a cluster" means a cluster you can use** — every node Ready and
every `kube-system` pod Running — not the moment the command returns. Those
are not the same for every tool, and the gap is where most of this row lives:

| | the command returns | usable | still settling |
|:--|--:|--:|--:|
| `kind create cluster` | **7.7 s** | 26.6 s | 18.9 s |
| `ferry up` | 12.7 s | **12.9 s** | 0.3 s |

kind hands the prompt back after 7.7 s and finishes bringing the cluster up
behind you; `ferry up` waits for CoreDNS before it says it is up, and is then
done. Timing "when the command returned" would make kind look 1.6× faster
here and it is 2× slower to a cluster that works — so the table times the
second column for both.

Both stacks pay about the same for the part neither controls: kube-controller-
manager takes 7.5 s on ferry and 8.9 s on kind to get from starting up to
running its deployment controller, and CoreDNS is a Deployment, so its pod
cannot exist until that happens.

**Idle memory is one measurement, taken the same way for every column** —
physical footprint on the Mac, of that stack's VMs and its own daemons, with
the cluster up and nothing scheduled. That is a correction. The table used to
print ferry's host-side footprint beside kind's memory *used inside Docker's
VM* and call both "idle memory", which made mode 2 read as 1,485 MiB against
kind's 695 and cost ferry a comparison it wins.

The indented row is why the top one is not the whole story either way. Docker
Desktop holds **15.6 GiB and 16 CPUs before the first pod exists**, and is
charging the Mac 1.7 GiB while doing nothing — so if you already run it for
other work, kind's marginal cost is the difference, 2,463 MiB, and if you
don't, it is the whole 4,148. A pod on kind then costs the Mac nothing extra:
it costs a slice of a VM already taken, and when the slice is gone, pods stop
fitting. ferry reserves nothing, so the two numbers are the same and the
indented row is zero.

Mode 1 trades memory for isolation and does not hide it — a pod is a VM with
its own kernel, and 240 MiB each is what that costs. Mode 2 is the other end:
14 MiB a pod against kind's 20, on the same host basis, and still no Docker.

Read inside the guest instead — the basis kind's cell used to be on — mode 2's
node holds 227 MiB against kind's 769 and minikube's 698. That row flatters
ferry and is not the one above: kind and minikube put an entire cluster inside
one guest, while mode 2's guest holds only the node, its control plane being
the native processes already counted in the host row.

**Where ferry is slower, it is slower.** kind starts 20 pods faster than
ferry mode 2 at full durability — 0.89 s against 1.19 s — and deletes a
cluster a shade faster than mode 2 does. Mode 2 also takes twice as long as
mode 1 to create, because it is a mode 1 control plane with a Linux node
booted on top of it. Relaxed durability turns the burst around (0.77 s) and
is the setting to reach for if that row is the one you care about, but at full
durability the row belongs to kind.

Deleting used to be on that list and is not any more, which took three
rounds. Both it and mode 2's creation were mostly waiting rather than work:

- **Teardown** was 3.9 s in mode 1 and 8.1 s in mode 2. `kube-apiserver` spent
  two seconds draining its watches — and on `--purge`, draining them into a
  data directory deleted milliseconds later. Every teardown loop polled at
  half-second ticks for processes that exit in tens of milliseconds. A fixed
  `sleep 1` waited on a service proxy that does not exit on SIGTERM at all.
  The components were then stopped one at a time, and the control plane after
  all of them, though on `--purge` nothing between the two needs an API
  server. Signals now go out in order and the waits overlap.
- **Mode 2 creation** was 32.6 s. Seven of those seconds were the node not
  being Ready, because the kubelet cannot report `NetworkReady` until its CNI
  configuration exists and that was written after an eight-second sleep whose
  only job was logging diagnostics. Another 4.6 s went on `ferry-karpenter`
  failing to start: it binds port 8081 for its health probe, which — unlike
  every other port ferry uses — was not shifted per profile, so a second
  ferry on the same Mac panicked on it.

`--purge` now skips the drain, plain `ferry down` keeps it because that
cluster is meant to come back, the ticks are 50 ms, the diagnostics run in the
background, and karpenter's port is shifted with the rest.

### Durability is a choice, and it is yours

The row that says **writes survive power loss** is the one to read first,
because it is the only row where kind and minikube have no answer.

`ferry up` defaults to **full** durability: every etcd commit reaches the SSD
before it is acknowledged. Nothing else in this table does that. kind and
minikube run etcd inside Docker Desktop's Linux VM, where the same call
reaches a disk image on the host — acknowledged, not yet durable. Pull the
power mid-write and they can lose commits the API server already confirmed.

That guarantee is not free, and it is not always wanted:

```sh
ferry up                        # full durability, the default
ferry up --durability relaxed   # speed instead, remembered for this cluster
```

| | mode 2 `full` | mode 2 `relaxed` | mode 1 `full` | mode 1 `relaxed` |
|:--|--:|--:|--:|--:|
| start one pod | 0.57 s | **0.52 s** | 0.46 s | 0.40 s |
| start 10 | 0.85 s | **0.60 s** | 1.70 s | 0.63 s |
| start 20 | 1.19 s | **0.77 s** | 3.39 s | 3.27 s |
| an etcd commit | 9.7 ms | **0.14 ms** | 9.7 ms | 0.14 ms |
| survives power loss | **yes** | no | **yes** | no |

In mode 2 that turns a 20-pod burst from slower than kind into faster than it,
1.19 s to 0.77 s against kind's 0.89 s. In mode 1 it does nothing for a
20-pod burst at all — 3.39 s to 3.27 s — because a pod there is a virtual
machine booting and `fsync` was never what it was waiting for. The flag is
worth reaching for on mode 2 and close to pointless on mode 1.

It is the right setting for a cluster you recreate from a script, and the
wrong one for a cluster holding something you would have to rebuild by hand.
`ferry status` says which one you are on, and `ferry up` warns every time it
starts a relaxed cluster, so it cannot become a thing you forgot.

**Why the gap exists at all.** macOS has two durability calls: `fsync(2)`
hands the data to the OS, and `fcntl(F_FULLFSYNC)` flushes the drive's own
write cache. Go's `os.File.Sync()` is `F_FULLFSYNC` on darwin and `fsync(2)`
on linux — and etcd is Go. Measured on this Mac, same SSD:

| | |
|:--|--:|
| `fsync(2)`, natively on macOS | 0.031 ms |
| **`F_FULLFSYNC`, natively on macOS** | **3.961 ms** |
| `fsync(2)`, inside Docker Desktop's VM | 0.042 ms |

So ferry's etcd, running natively, asks the SSD to flush on every commit and
waits ~4 ms for it. kind's etcd makes the identical Go call on Linux, where
it compiles to the cheap one. The same source line, 128× apart, decided by
which kernel it was built for. kind is not skipping a step ferry takes — it
is running where that step is not offered, and it cannot opt back in.

Measured by [experiment 24](experiments/24-benchmark-harness/FINDINGS.md) on:

| | |
|:--|:--|
| machine | MacBook Pro, Apple M4 Max, 16 cores (12P + 4E), 128 GB |
| macOS | 26.6.2 (25G83), APFS on the internal SSD |
| Docker Desktop | 29.2.1 — its VM sized 16 CPUs / 15.6 GiB |
| kind / minikube | v0.32.0 / v1.38.1 |
| Kubernetes | v1.37.0 on all four |

**What it does not establish.** One run per stack, so these are the shape of
the difference and not three significant figures. Pod-start times are polled
rather than watched and carry roughly 40 ms of the harness's own loop —
watched, mode 2's single pod is nearer 190 ms. Disk is deliberately not in the
table: ferry's figure would include the node image it boots and kind's would
not, because that image is shared with every other cluster kind makes. The
per-pod figures for kind and mode 2 are a few MiB read inside a guest and are
noisy at this scale — the 10-pod cell put kind at 0.9 MiB a pod and the 20-pod
cell at 5.8.

**Every row above is one battery**, re-run 2026-09-21 after three things were
found wrong with the previous one. Each is now recorded per stack in
`results/raw.tsv` rather than left to be noticed:

- **A Docker-based stack needs Docker restarted before its baseline.** Docker
  Desktop's VM does not release pages when a cluster is deleted — measured at
  3,891.2 MiB before a `kind delete` and 3,891.2 MiB after — so minikube,
  running second, inherited kind's pages as its baseline and its own cluster
  fitted inside memory already charged. That is why the cluster was once
  reported as adding 10 MiB. Restarted first, it adds 1,953 MiB — the 3,632
  above, less the 1,679 Docker was holding before it. ferry needs no
  equivalent: its VMs exit with the cluster, so its baseline is a real zero.
- **Durability has to be passed, not inherited.** `ferry up` remembers the
  setting per cluster and `ferry down --purge` does not clear it, so an
  unflagged run silently takes the last one's. Measured that way, all four
  ferry columns came out `relaxed` and mode 2's 20-pod burst read 0.64 s
  instead of 1.19 s — a number that would have had mode 2 beating kind on a
  row it loses. The harness now passes `--durability` every time and records
  what `ferry status` reports back.
- **An unreadable VM is not a free one.** `vmmap` occasionally returns nothing
  for a process, and the footprint helper used to skip it silently, so a mode 2
  cluster reported 670.8 MiB across two VMs where every comparable run reported
  ~980. Reads that fail are now counted into a `footprint_unread` row.

**Mode 2's node is sized as ferry ships it,** 2 GiB, not the 15 GiB the harness
used to mirror Docker Desktop with. A ceiling is not free even untouched — the
guest kernel allocates a `struct page` per 4 KiB of it at boot — so 15 GiB cost
1,538 MiB idle against 1,182, and bought nothing: the 20-pod burst is
1.22–1.26 s across 2, 4, 8 and 15 GiB, medians of three.

Pod semantics fall out of the VM boundary: one VM is one network stack, so
containers in a pod share localhost and IPC by construction. No pause
container, no network namespace plumbing.

None of that changes if you want density instead. A `Machine` is a Linux node VM
whose pods are ordinary containers sharing its kernel — ~45ms to start one
against ~300ms for a pod VM — and a pod picks with
`nodeSelector: {ferry.dev/mode: shared}` or `vm-per-pod`. It is still nothing to
size up front, and not because sizing is easy here — because you never do it. A
pod that fits nowhere causes a machine shaped to fit it, and an idle machine is
taken away again — which is what returns its memory, since a VM that keeps
running keeps the pages it has touched. Off until `ferry machines enable`;
[docs/MACHINES.md](docs/MACHINES.md) is the case for it and what it costs.

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
  workloads. `kubectl get nodes` reports `OS-IMAGE: macOS 26.6.2`; a 10-replica
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
- ✅ **Volumes work.** Mounts become virtiofs shares into the pod VM. Projected
  ServiceAccount tokens, ConfigMaps and emptyDir all verified — including a pod
  that authenticates to the API server with its own token. A ReadWriteOnce
  PersistentVolume and an emptyDir are each an ext4 disk image attached to the
  pod's VM instead, so `chown` works on them: virtiofs is served as the Mac user, which cannot give a
  file away, and an init container that chowns its data directory — most
  stateful charts have one — crashlooped forever on a share. An emptyDir with
  `medium: Memory` is a tmpfs inside the pod's VM, sized by its `sizeLimit`,
  and carried across the VM rebuilds that container restarts and init
  containers cause. See
  [experiments/30-volumes-and-logs](experiments/30-volumes-and-logs/FINDINGS.md).
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
  `127.0.0.1`. Native sidecars (`restartPolicy: Always` init containers) and
  init containers share it too.
- ✅ **A container restarts inside its running pod.** Each image a pod runs is
  one read-only disk and a container's root is an overlay on it, so joining a
  running VM needs no new device: a crashed container is back in **~45ms**,
  its siblings keep their PIDs, and the pod keeps its address. The same path
  runs `kubectl debug` containers and pods of 70 containers, and N containers
  of one image cache it once. See
  [experiments/31-restart-in-place](experiments/31-restart-in-place/).
- ✅ **`kubectl exec` works** — stdin, stderr and exit codes included. CRI
  carries exec over SPDY rather than gRPC, so `ferry-streamer` terminates that
  using Kubernetes' own streaming server and hands the request to `ferry-cri`.
- ✅ **Services route inside the pods, with kube-proxy's own rules.**
  `ferry-proxyd` runs kube-proxy's rule generation natively on macOS and renders
  the ruleset; each pod applies it to its own kernel. Traffic goes pod to pod
  and nothing needs root. See [docs/SERVICES.md](docs/SERVICES.md).
- ✅ **Pods can use the Mac's GPU.** Not pass-through -- there is none on Apple
  silicon, and Metal is reachable only from a macOS process. `ferry-gpud` holds
  the GPU and a pod that requests `ferry.dev/gpu` is handed a unix socket to it,
  relayed into its VM over vsock. A scheduled pod reached 9.4 TFLOP/s of Metal
  matmul and ran the on-device model; a second pod requesting it waits on the
  scheduler, with no device plugin anywhere. Pods share the device by preemption
  -- a pod wanting a fraction of a second waits 0.6s while another holds 35
  seconds of work, or 0.1s if its PriorityClass outranks the pod holding the
  device -- and `kubectl` shows what each pod has used. See
  [docs/GPU.md](docs/GPU.md) and
  [experiments/08-vsock-socket-relay](experiments/08-vsock-socket-relay/FINDINGS.md).
- ✅ **Cluster DNS works.** CoreDNS runs as a pod on an address reserved before
  any pod can take it, so the kubelet can be told where DNS lives before DNS
  exists. Pods resolve external names and cluster names.
- ✅ **Cluster upgrades work.** `ferry upgrade plan|apply|nodes|rollback` moves
  the control plane in place against the same etcd, then drains and replaces
  each kubelet while the runtime keeps holding the pod VMs. A cluster went
  v1.34.0 → v1.34.11, back, and forward again: the workload kept the same pods,
  the same IPs and zero restarts across the control plane switch, and rollback
  lost nothing because the etcd minor did not change. One version now drives the
  kubelet, the control plane and etcd together, which it did not before — asking
  for a newer one used to produce a kubelet newer than the API server, silently.
  See [docs/UPGRADES.md](docs/UPGRADES.md).
- ✅ **A second mode, where the node is the VM.** `kubectl apply` a `Machine`
  and a Linux node VM joins the cluster **Ready in 16 seconds**, running
  containerd and a stock kubelet; `kubectl delete` takes it away in 3, VM
  stopped, `Node` removed, disk cleaned up behind a finalizer. Pods on two
  machines reach each other, each node routing to the others' pod CIDR slices.
  A pod chooses between the modes with
  `nodeSelector: {ferry.dev/mode: shared | vm-per-pod}`, which is node selection
  rather than a new concept.

  Nobody declares that `Machine` in the ordinary case. A pending pod that fits
  no existing node creates one sized to fit it, and an empty machine is
  reclaimed a minute later — Karpenter, with ferry as its cloud provider,
  running natively beside the control plane rather than as a pod in the cluster
  it provisions for. Pods reach each other across both modes at their real
  addresses, so one `Deployment` can span the Mac node and a machine. Off until
  `ferry machines enable`. Built through milestone 6; GPU into machines is not.
  See [docs/MACHINES.md](docs/MACHINES.md).
- ✅ **ferry installs in one line.** `curl -sfL https://get.ferry.kurpuis.com |
  sh -` downloads a release, verifies it, puts `ferry` and a matching `kubectl`
  on the PATH, registers a login agent and starts a cluster — Apple silicon and
  macOS 26 the only requirement, no Swift, no Go, no Kubernetes source tree and
  no `sudo`. Another Mac joins with one line carrying a token, so nothing copies
  binaries by hand any more. See [docs/INSTALL.md](docs/INSTALL.md).

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
install.sh                           what get.ferry.kurpuis.com serves: curl | sh
CNAME                                the domain, copied into the published site
.github/workflows/pages.yml          publishes install.sh to that domain from main
release/build.sh                     package a built checkout into a release tarball
release/publish.sh                   put one on GitHub Releases
ferry                                the CLI: doctor, build, up, down, status, logs,
                                     upgrade, machines, service, uninstall
lib/versions.sh                      the version store, and what may follow what
lib/addons.sh                        ferry addons: render, fetch, apply, wait, record
addons/                              the addons, each an addon.conf and manifests
build-kubelet.sh                     build darwin kubelet from upstream + overlay
patches/kubelet/                     platform implementations, mirroring upstream paths
patches/kubelet-vX.Y/                per-minor shims, laid over the shared tree
control-plane/                       PKI + up/down for the native control plane
manifests/                           CoreDNS, rendered at 'ferry up'
manifests/machines/                  kube-proxy and CoreDNS for mode 2's machines
tests/                               what can be checked without a cluster
docs/                                HANDOFF.md (the full picture), INSTALL.md,
                                     MACHINES.md (mode 2), SERVICES.md,
                                     BENCHMARKING.md (how to measure this honestly)
experiments/01-kubelet-cri-surface/  fake CRI runtime + harness
experiments/02-node-registration/    the Mac as a node, against the real API
experiments/03-vm-ceiling/           how many VMs macOS runs, and how fast
experiments/04-pod-networking/       routable per-pod addressing, host and pod to pod
experiments/05-real-pods/            the whole stack, with real VMs per pod
experiments/06-kube-proxy-on-macos/  kube-proxy's rule generation, rendered on darwin
experiments/07-vmnet-leak/           what a refused vmnet subnet actually means
experiments/08-vsock-socket-relay/   a host socket, inside a pod, over vsock
experiments/12-gpu-contention/       what shares this Mac's silicon and what does not
experiments/17-node-vm/              a Linux node VM joining, in six and a half seconds
experiments/18-node-image/           the node image, and ferry-node that boots it
experiments/19-machine-crd/          a node made by applying a resource
experiments/20-pod-network/          pods on two machines reaching each other
experiments/21-density-vs-kind-minikube/  against kind and minikube, on one Mac
experiments/22-vmnet-lifecycle/      why a vmnet subnet stays reserved
experiments/24-benchmark-harness/    the repeatable battery, and what it found
ferry-cri/                           the CRI runtime: one VM per pod
ferry-machined/                      mode 2: Machine objects into node VMs, and the CRD
node-image/ (built)                  mode 2's node image, as an OCI layout
ferry-streamer/                      SPDY streaming for exec, attach and port-forward
ferry-proxyd/ (in patches/)          kube-proxy's rule generation, built for darwin
guest/                               nft, bundled with its loader for pods
ferry-proxy/                         host-side ClusterIP routing (fallback)
ferry-gpud/                          the Mac's GPU, offered to pods over a socket
kernel/                              guest kernel with NAT support
assets/                              the logo
bin/versions/<vX.Y.Z>/               kubelet, control plane and etcd per version
bin/                                 build output, symlinked to a version (gitignored)
```

## Install

```sh
curl -sfL https://get.ferry.kurpuis.com | sh -
```

That downloads a release, puts `ferry` and a matching `kubectl` on your PATH,
registers a login agent so the cluster comes back after a reboot, and starts it.
No Swift, no Go, no Kubernetes source tree, and no `sudo` — the release carries
the kubelet, the control plane, etcd, the runtime and the guest kernel already
built.

Adding a second Mac is one line from the first Mac's `ferry token create`:

```sh
curl -sfL https://get.ferry.kurpuis.com | FERRY_URL=mac1.local:6443 FERRY_TOKEN=F10… sh -
```

A release also carries **mode 2** — the node as the VM, pods sharing its kernel
([docs/MACHINES.md](docs/MACHINES.md)) — off until `ferry machines enable`.

Details, the environment variables, and how to uninstall are in
[docs/INSTALL.md](docs/INSTALL.md). To build ferry instead of installing it, see
[Building from source](#building-from-source).

## Try it

```sh
export KUBECONFIG=~/.ferry/admin.conf     # or: ferry kubeconfig --merge
kubectl run demo --image=ghcr.io/linuxcontainers/alpine:3.20 --restart=Never \
  --command -- /bin/sh -c "echo hello from a VM; sleep 3600"

kubectl get pods -o wide          # each pod has its own routable address
kubectl logs demo
ping "$(kubectl get pod demo -o jsonpath='{.status.podIP}')"

# Services route inside the pods, using kube-proxy's own rules
kubectl run web --image=busybox --restart=Never \
  --command -- sh -c "echo hi from a Service > /tmp/index.html; httpd -f -p 8080 -h /tmp"
kubectl expose pod web --port 80 --target-port 8080
kubectl run probe --image=busybox --restart=Never --command -- sleep 3600
kubectl exec probe -- wget -qO- http://web

ferry status
ferry down
```

`ferry doctor` explains what is missing if the machine is not ready.

### Building an image, without Docker

```sh
ferry image build -t myapp:dev .      # buildkit in a pod; nothing else needed
kubectl run myapp --image=myapp:dev --image-pull-policy=IfNotPresent
```

The builder is buildkit running as an ordinary pod — its own kernel, so it gets
the namespaces and the overlayfs it wants without anything on the Mac being
relaxed. The client is `buildctl`, which talks to the pod at the address
Kubernetes knows it by, because the Mac is on that subnet already: nothing is
forwarded and nothing is proxied. The result goes straight into the image store
pods are served from, so there is no registry in the loop.

That store is one node's, so every image loaded or built is also kept by
`ferry-registry` and served read-only to every other node in the cluster: the
other nodes on this Mac ask it before the real registry, mode 2 machines ask it
at their gateway, and it asks the other Macs' registries -- over TLS, where
only the cluster's nodes are answered -- for anything it does not hold. The
image reference does not change. Use `imagePullPolicy: IfNotPresent`; `Never`
works on this Mac's nodes, which a load fills directly. See
`FERRY_MACHINE_REGISTRY` in [docs/INSTALL.md](docs/INSTALL.md).

It needs `buildctl` (`brew install buildkit`) and nothing else. Docker Desktop
does not have to be installed, let alone running.

The builder speaks mutual TLS, because it has to listen on the pod's real
address -- that is the only path the Mac has to it -- and that address is on a
network every pod shares. A privileged build daemon anything could drive would
be a way to run as root in a VM holding your whole build cache. ferry issues a
CA, a server certificate and one client certificate into `~/.ferry/pki/builder`
on the first build; the daemon requires the client certificate and the Mac has
the only copy. A NetworkPolicy denying every pod goes on as well, though that
one only bites on a kernel built by `ferry kernel` -- the stock guest kernel has
no nftables to enforce it with.

Against the workflow it replaces — `docker buildx build` and then `kind load
docker-image`, both warm, from an edited file to a cluster that can run it:

| | `ferry image build` | docker + `kind load` |
|:--|--:|--:|
| alpine, one COPY | **0.47 s** | 1.02 s |
| node app, 92 MB | **1.34 s** | 2.08 s |
| python app, 449 MB | **5.37 s** | 6.69 s |

The builder stays up between builds, because its layer cache is what makes the
second build fast and it costs about 330 MiB of lazily-backed guest memory to
keep — against the 1,741 MiB Docker Desktop's VM occupies before it has built
anything. `ferry image build --stop` ends it. Measured in
[experiment 25](experiments/25-build-without-docker/FINDINGS.md).

### Addons

```sh
ferry addons list
ferry addons enable registry          # localhost:5001, for the Mac and for pods
crane copy busybox:1.36 localhost:5001/busybox:1.36
kubectl run hi --image=localhost:5001/busybox:1.36 --restart=Never -- echo hi
```

Ten, each pinned to a version that has been run here and checked for what it is
for, not only for its pods going Ready: metrics-server, ingress-nginx, a
registry, the Kubernetes Dashboard and Headlamp, cert-manager, the Gateway API
CRDs and Envoy Gateway, kube-state-metrics and a single Prometheus. `enable`
waits until the addon works and says why when it does not; `disable` removes
exactly what was applied. Upstream manifests are fetched by sha256 and cached,
so a second enable needs no network. Every pod is a VM of roughly 300 MiB, so
the addons are the lean variants, and [addons/README.md](addons/README.md) lists
each one's pods and measured memory.

### Limits worth knowing

- **A container can join a running pod only with an image the pod already
  runs.** `Virtualization.framework` cannot attach a disk to a running VM, and
  images are disks: the VM attaches every image the pod spec names that is
  pulled when it boots. A restart, a sidecar, and a `kubectl debug` container
  of one of those images join in place. A regular container with any other
  image — one still pulling at boot — has the pod recreated around it; a
  `kubectl debug` container with another image is refused rather than
  restarting the pod. A block volume that arrives after the boot is the same.
- **The cluster starts at login, not at boot.** `Virtualization.framework` will
  not make a VM from a process outside a user session, so the login agent is a
  LaunchAgent rather than a LaunchDaemon. A Mac that reboots to the login window
  holds the cluster there until somebody logs in — and a Mac that *joined*
  another cluster does not come back at all, because a worker's credentials live
  under `/tmp`. Rejoin it with a fresh token.
- **Services** route inside each pod using kube-proxy's own rules and need no
  privilege on the Mac — the release ships the guest kernel that makes this
  work; a checkout has to `ferry kernel` first, or ferry falls back to a host
  proxy that does need root. Conntrack is not reconciled. TCP and UDP are
  verified end to end; SCTP inside the cluster only, since macOS has no SCTP
  for a NodePort or LoadBalancer to be served with
  ([experiment 27](experiments/27-edge-policy-sctp/FINDINGS.md)).
- `logs`, `exec`, `port-forward` and `attach` all work. Attach needs the pod to
  set `stdin: true` to accept input, since the stream has to be wired in when
  the container is created.
- **Memory can decide how many pods fit, before the 128-VM ceiling does.** An
  idle pod VM costs **133 MiB** of host memory before its workload does
  anything — flat at 20 and 60 pods. It was 226 MiB until
  [experiment 32](experiments/32-pod-memory-footprint/FINDINGS.md) found most of
  that was read-ahead into the guest agent's binaries and a kernel carrying
  drivers no VM has. Only the guest agent's own disk keeps the small
  read-ahead that saving came from. A pod's image and volume disks read ahead
  1 MiB, which triples a 64 KiB-block read of a large file (4.8 → 14.4 GB/s)
  for 0-4 MiB on alpine, nginx or python, and 17 MiB on node, whose 120 MiB
  binary is paged in by the window. Set `FERRY_POD_READAHEAD_KB` for the node,
  or the `ferry.dev/read-ahead-kb` annotation for one pod. A bigger VM costs
  about 21 MiB more per GiB it is given.
  ferry sets `maxPods` from the machine's memory, budgeting half of it for that
  overhead: 110 from 32 GiB up, 61 on a 16 GiB Mac, overridable with
  `FERRY_MAX_PODS`. The hypervisor's 128-VM ceiling is still shared — every
  other VM, Docker Desktop included, takes one of ferry's slots. See also
  [experiments/13-shared-kernel-cost](experiments/13-shared-kernel-cost/FINDINGS.md).
- **Restarting in quick succession moves the pod network.** A vmnet subnet stays
  reserved for about a minute after the run using it stops, and there are 32
  networks across the whole Mac, so a restart takes the next free subnet. Pods
  and Services are unaffected; CoreDNS rolls out again because the gateway is
  part of its config. See
  [experiments/07-vmnet-leak](experiments/07-vmnet-leak/FINDINGS.md).
- **`ferry down` leaves the cluster's objects in etcd.** It stops processes; it
  does not delete anything. Pods come back on the next `ferry up`.

## Requirements

To **run** ferry, which is what `curl -sfL https://get.ferry.kurpuis.com | sh -` does:

- Apple silicon, macOS 26 (Tahoe)

That is the whole list. The release is built binaries, ad-hoc signed — including
the `com.apple.security.virtualization` entitlement `ferry-cri` needs, which is a
hash of the binary itself and so survives the trip to another Mac.

## Building from source

Only needed to change ferry. Everything below is a *build* dependency; a Mac
running a cluster needs none of it.

```sh
git clone https://github.com/imaustink/ferry && cd ferry
./ferry doctor    # check this machine can build ferry
./ferry build     # kubelet, runtime, guest kernel
./ferry up
```

- Go 1.24+
- Docker, for `ferry kernel` — the guest kernel is the one slow build, and the
  only reason a release is packaged on a Mac rather than in CI.
- **Swift 6.2+, and 6.4 is what ferry is built with.** Use the same toolchain on
  every Mac in a cluster: binaries are copied between machines, and two
  toolchains produce two builds that are only probably the same. A release
  sidesteps this — every Mac installing it gets the same binaries, and the
  toolchain that made them is recorded in its `VERSION`.

  The OS upgrade does not bring the toolchain with it, and the version Apple
  offers moves, so ask before installing:
  ```sh
  softwareupdate --list | grep "Command Line Tools"
  sudo rm -rf /Library/Developer/CommandLineTools          # see below
  sudo softwareupdate --install "Command Line Tools for Xcode <version>"
  ```

  **Remove the old one first.** Both `softwareupdate --install` and
  `xcode-select --install` lay a version down beside whatever is already there,
  and the result reports a healthy version number while being unable to build
  anything — a 6.3 driver reading 6.4 module interfaces, or a `swift-package`
  that dies in dyld before it reads a manifest. `ferry doctor` checks for this
  by running SwiftPM rather than by asking it its version.

Most of this was developed on macOS 15. What actually needs 26 is routable
per-pod addressing (`VZVmnetNetworkDeviceAttachment`) and the toolchain Apple's
Containerization framework requires to build.

### Cutting a release

```sh
./ferry build && ./ferry kernel && ./ferry node-image   # everything the tarball carries
git tag -a v0.1.0 -m "..." && git push origin v0.1.0
./release/build.sh --version v0.1.0
./release/publish.sh --version v0.1.0      # a draft; --publish to go live
```

`release/build.sh` packages the runtime subset of the checkout and refuses to
ship one that is missing a piece — including mode 2's node image, unless told
`--without-node-image`, which the release then records. `release/publish.sh`
refuses a dirty tree, or a tarball built from a commit other than the tag's.

`install.sh` itself is served from GitHub Pages, republished from `main`
whenever it changes, so the installer people run is the one in this repository.
The one-time DNS and Pages setup is in [docs/INSTALL.md](docs/INSTALL.md).
