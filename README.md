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

| | ferry | ferry, mode 2 | kind | minikube |
|:--|--:|--:|--:|--:|
| a pod is | its own VM | a container | a container | a container |
| needs Docker Desktop | **no** | **no** | yes | yes |
| create a cluster | **12.3 s** | 25.9 s | 25.4 s | 30.3 s |
| delete it | 1.2 s | 1.4 s | **0.5 s** | 12.5 s |
| start one pod | 0.50 s | **0.25 s** | 0.61 s | 0.60 s |
| start 10 | 0.99 s | **0.64 s** | 0.70 s | 1.08 s |
| start 20 | 3.56 s | 1.17 s | **0.93 s** | 2.18 s |
| idle memory | **431 MiB of the Mac** | 1,491 MiB of the Mac | 695 MiB of a VM you sized | 667 MiB of a VM you sized |
| idle CPU | **2.8%** | 14.4% | 24.4% | 29.0% |
| per pod | 239 MiB | 9 MiB | 6 MiB | 16 MiB |

CPU is percent of one core over a 60-second window with the cluster up and
nothing scheduled. This Mac has sixteen.

**The two memory columns cannot be the same number, and the reason is the
point.** Docker Desktop holds **15.6 GiB and 16 CPUs before the first pod
exists**, so a pod on kind costs the Mac nothing extra — it costs a slice of a
VM already taken, and when the slice is gone, pods stop fitting. Before any
cluster at all, Docker Desktop was already charging this Mac 1.7 GiB and 7% of
a core. ferry reserves nothing: an idle mode 1 cluster is 432 MiB of real
memory and 3.1% of one core, and there is no VM to size.

Mode 1 trades memory for isolation and does not hide it — a pod is a VM with
its own kernel, and 240 MiB each is what that costs. Mode 2 is the other end:
9 MiB a pod, on kind's own basis (read inside the guest, the way kind is
read), and still no Docker.

**Where ferry is slower, it is slower.** kind creates 20 pods faster than
ferry mode 2 out of the box, deletes a cluster in half a second against
ferry's one and a bit, and costs less per pod. Mode 2 takes twice as long as
mode 1 to create, because it is a mode 1 control plane with a Linux node
booted on top of it.

Both of those numbers used to be worse, and almost none of the difference was
work:

- **Teardown** was 3.9 s in mode 1 and 8.1 s in mode 2. `kube-apiserver` spent
  two seconds draining its watches — and on `--purge`, draining them into a
  data directory deleted milliseconds later. Every teardown loop polled at
  half-second ticks for processes that exit in tens of milliseconds. A fixed
  `sleep 1` waited on a service proxy that does not exit on SIGTERM at all.
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

That 20-pod row is the one number here that moves a lot on a flag:

| ferry mode 2 | default | `FERRY_ETCD_NO_FSYNC=1 FERRY_NODE_DISK_SYNC=none` |
|:--|--:|--:|
| start one pod | 0.25 s | **0.21 s** |
| start 10 | 0.64 s | **0.26 s** |
| start 20 | 1.17 s | **0.41 s** |

Both default to off, because they relax durability and that is the cluster's
data. On a cluster you recreate on demand they are close to free, and they
take the 20-pod burst from behind kind to **2.3× ahead** of it. Most of what
they buy back is fsync: ferry's etcd runs natively on APFS and pays a real
barrier per write, while kind's runs inside Docker Desktop's VM, where a guest
fsync reaches a virtual disk whose host-side durability Docker has already
relaxed.

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
watched, mode 2's single pod is nearer 190 ms. Memory is read where each stack
keeps it: on the Mac for ferry, inside Docker's VM for kind and minikube,
which is the only way to compare them and is not the same instrument twice.
Disk is deliberately not in the table: ferry's figure would include the node
image it boots and kind's would not, because that image is shared with every
other cluster kind makes. The per-pod figures for kind and mode 2 are a few
MiB read inside a guest and are noisy at this scale — the 10-pod cell put kind
at 0.9 MiB a pod and the 20-pod cell at 5.8.

Pod semantics fall out of the VM boundary: one VM is one network stack, so
containers in a pod share localhost and IPC by construction. No pause
container, no network namespace plumbing.

None of that changes if you want density instead. A `Machine` is a Linux node VM
whose pods are ordinary containers sharing its kernel — ~45ms to start one
against ~300ms for a pod VM — and a pod picks with
`nodeSelector: {ferry.dev/mode: shared}` or `vm-per-pod`. It is still nothing to
size up front, and not because sizing is easy here — because you never do it. A
pod that fits nowhere causes a machine shaped to fit it, and an idle machine
gives its memory back to the Mac. Off until `ferry machines enable`;
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

### Limits worth knowing

- **A pod's containers are fixed at boot.** `Virtualization.framework` cannot
  hotplug, so the VM does not start until the kubelet has created every container
  in the pod. Sidecars work and share `127.0.0.1`; init containers work, each
  exiting before the next is created, with shared volumes carrying state across.
  What cannot happen is a container joining a pod whose VM is already running.
- **The cluster starts at login, not at boot.** `Virtualization.framework` will
  not make a VM from a process outside a user session, so the login agent is a
  LaunchAgent rather than a LaunchDaemon. A Mac that reboots to the login window
  holds the cluster there until somebody logs in — and a Mac that *joined*
  another cluster does not come back at all, because a worker's credentials live
  under `/tmp`. Rejoin it with a fresh token.
- **Services** route inside each pod using kube-proxy's own rules and need no
  privilege on the Mac — the release ships the guest kernel that makes this
  work; a checkout has to `ferry kernel` first, or ferry falls back to a host
  proxy that does need root. Conntrack is not reconciled, and only TCP has been
  verified.
- `logs`, `exec`, `port-forward` and `attach` all work. Attach needs the pod to
  set `stdin: true` to accept input, since the stream has to be wired in when
  the container is created.
- **Memory decides how many pods fit, not the 128-VM ceiling.** An idle pod VM
  costs **226 MiB** of host memory before its workload does anything — flat at
  8, 20, 24 and 40 pods, and unmoved by `--pod-memory-mib`, so it is the price
  of a kernel rather than a pod using its allowance. 110 of those is 24 GiB.
  ferry therefore sets `maxPods` from the machine's memory, budgeting half of it
  for that overhead: 72 on a 32 GiB Mac, 110 on a 64 GiB one, overridable with
  `FERRY_MAX_PODS`. The hypervisor's 128-VM ceiling is still shared — every
  other VM, Docker Desktop included, takes one of ferry's slots — but on most
  Macs memory runs out first. See
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
