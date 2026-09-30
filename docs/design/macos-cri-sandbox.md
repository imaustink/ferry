# Design: macOS pods as host-scheduled VM sandboxes

Status: in progress (Stage 2). Stage 1 — removing `ferry-macos-shared` — landed
separately.

## Problem

A macOS pod is slow to start: ~17s (and ~35s for the VM-per-pod class) because
each pod provisions a whole macOS **Node**. Karpenter makes a `Machine`,
ferry-machined clones+boots a macOS guest (~9–21s), the guest joins the cluster
with its *own* kubelet and CRI, and only then does the pod run. A Linux pod, by
contrast, gets a VM *sandbox* straight from `ferry-cri` on the existing host
node in ~0.3s — no Karpenter, no second kubelet, no node registration.

The asymmetry is not fundamental. The host Mac is already macOS; the extra node
exists only because `ferry-cri` boots **Linux** guests (Apple's Containerization
`LinuxPod` + `VZVirtualMachineManager`, which inject vminitd), so a Darwin
workload had nowhere to run but a separate guest.

## Goal

Run a `ferry-macos-vm` pod as a **macOS VM sandbox booted by `ferry-cri` on the
host node**, the same shape as a Linux `ferry-vm` pod: one single-use XNU kernel
behind the hypervisor, no separate Node. This removes the Karpenter round-trip
and the in-guest kubelet/CRI bring-up — the bulk of the latency — and deletes a
large amount of machinery (the darwin path in ferry-machined and ferry-karpenter,
the `macos-vm` NodePool).

Isolation is unchanged: still a VM per pod. macOS stays VM-per-pod only (mode 2,
the shared-kernel class, was removed in Stage 1).

## Constraints

- **Apple's 2-VM licence ceiling.** A Mac runs at most two macOS VMs at once
  (enforced by Virtualization.framework; Linux VMs don't count). Today Karpenter
  enforces this by counting darwin `Machine`s against `maxMacOSGuests = 2`
  (`ferry-karpenter/shapes.go`). With no Machines, the cap must move into
  `ferry-cri` on the host node.
- **No hot-plug.** Virtualization.framework cannot add a device to a running VM,
  so `ferry-cri` already boots a pod's VM lazily on the first `StartContainer`
  once its images/volumes are known (`PodRuntime.bootPod`). The darwin path
  follows the same lazy-boot state machine.
- **The OS comes from the node.** A darwin image is `FROM macos` + `COPY`: it
  ships only the workload's own arm64 binaries; dyld and the shared cache come
  from the guest. So the container root is the golden image's OS base
  (`ferry-darwin -prepare` copies dyld + the 6.2 GB shared cache in at bake
  time) hard-linked under the image's files, run under `chroot` as the pod. This
  is exactly what `ferry-darwin` does today with `-pod-vm`.

## Approach: a darwin sandbox backend in ferry-cri

`ferry-cri` is one Swift actor, `PodRuntime`, behind a thin CRI adapter
(`FerryRuntimeService`). The CRI surface, the lazy-boot state machine, the
streamer/`ExecServer` exec-URL indirection, host-side CNI, log plumbing, and
teardown ordering are all **OS-agnostic and reused as-is**. Only the VM backend
and the guest control channel are Linux-specific.

### Hook points (all in `ferry-cri/Sources/ferry-cri/`)

1. **`RuntimeHandlers`** (`RuntimeService.swift`): advertise and accept
   `ferry-macos-vm`, and map a handler to a `RuntimeKind` (`linux` | `darwin`).
   *(Increment 1 — done.)*
2. **Thread the handler into `PodRuntime`.** `RuntimeService.runPodSandbox`
   drops `request.runtimeHandler` today; pass its `RuntimeKind` to
   `PodRuntime.runPodSandbox` and store it on `SandboxRecord`. Every later call
   (`createContainer`, `startContainer`, `exec`, `stats`, teardown) keys off the
   record, so the tag is enough for the whole lifecycle to dispatch.
3. **Fork VM construction/boot.** `makePod` / `bootPod` (`PodRuntime.swift`)
   assume `LinuxPod` + `VZVirtualMachineManager` + a Linux `Kernel` + vminitd
   initfs. A `DarwinSandbox` sibling instead:
   - clones the golden bundle (APFS `clonefile`, ~1ms — reuse the `clone()` in
     `ferry-macvm`/`ferry-node`),
   - boots a `VZMacOSVirtualMachineConfiguration` with the pod's network card
     and a config share (reuse `bootMac` in `experiments/18-node-image`
     `ferry-node/MacMachine.swift` — the production launch that already does
     vmnet + pod-switch attach by MAC and the `ferry-config`/`ferry-logs`
     virtiofs shares),
   - waits for the guest agent over vsock.
4. **Run the container.** Reuse `ferry-darwin` in the guest (OS base + `chroot`
   exec + image pull + logs/stats + `-pod-vm` = pod runs as root), but **drive
   it from the host `ferry-cri`** over vsock instead of an in-guest kubelet. The
   guest agent (`ferry-macagent`) today serves only *exec*; it must grow
   attach/logs/stats/stdin-streaming, or `ferry-darwin`'s existing
   `streaming.go`/`attach.go`/`stats.go` are exposed to the host over the vsock
   channel. Container start/stop map onto `startContainer`/`start`/`markStarted`
   the way the Linux reaper does.
5. **Networking / logs / exec.** Host-side CNI (`cniHostPlugins`, run as native
   macOS processes) and the exec-URL indirection (`ExecServer`/`StreamerClient`)
   are reused unchanged; the guest CNI chain and cgroup stats are replaced by the
   config-share network setup and `ferry-darwin`'s poll-based limits.

### The 2-VM ceiling, re-homed

`ferry-cri` (via the darwin kubelet's node config) advertises an extended
resource **`ferry.dev/macos-guest: 2`** on the host node, and the
`ferry-macos-vm` RuntimeClass charges `1` through its pod overhead. The
scheduler then caps concurrent macOS pods at two and leaves a third Pending —
the same effect Karpenter's `maxMacOSGuests` gave, without any Machines.
`ferry-cri` also refuses a third at `runPodSandbox` as a backstop.

### Scheduling

The `ferry-macos-vm` RuntimeClass drops its `nodeSelector: {ferry.dev/mode:
macos-vm}` (which forced a Machine node) and instead targets the host node the
way `ferry-vm` does (`ferry.dev/mode: vm-per-pod`), with the toleration for the
Mac's taint. The handler stays `ferry-darwin`'s successor served by `ferry-cri`.

## Increments

1. **CRI recognition + design (done).** `RuntimeHandlers` learns
   `ferry-macos-vm` and a `RuntimeKind`; the darwin path is guarded with a clear
   "not yet implemented on this node" error. Safe and inert: the RuntimeClass
   still pins darwin pods to Machine nodes, so host `ferry-cri` receives none
   yet. Unit-tested; no behaviour change.
2. **The `DarwinSandbox` VM backend (done — `DarwinSandbox.swift`).** The
   reusable core, adapted from `ferry-macvm`'s proven build coprocess: clone the
   golden bundle (APFS `clonefile`), boot a `VZMacOSVirtualMachineConfiguration`
   on its own queue, connect the guest agent over vsock, run a command streaming
   its stdout/stderr frames and returning the exit status, and tear down. The
   guest wire protocol (`DarwinFrameParser`, `DarwinRunRequest`) is a pure,
   unit-tested core (`DarwinFrameTests`). It compiles in CI; a real boot needs a
   golden image and Virtualization entitlements on Mac hardware.
3. **Wire `DarwinSandbox` into the CRI lifecycle (done — `DarwinRuntime.swift`).**
   Rather than make `SandboxRecord` (which hard-requires a `LinuxPod`) two OSes
   at once and thread darwin branches through every Linux path, darwin sandboxes
   live in their own `DarwinRuntime` actor and `FerryRuntimeService` routes an id
   to whichever side owns it — `PodRuntime` is untouched. `DarwinRuntime` owns
   the CRI lifecycle: create a sandbox, boot the `DarwinSandbox` lazily on the
   first `StartContainer`, run the container's command over the agent (streaming
   to the container log), report status/exit through OS-agnostic info structs the
   service turns into CRI protos, and tear down. `ferry-cri` takes the golden
   path via `--mac-image` (the `ferry` bash passes `resolve_mac_image`), and the
   two-VM ceiling is enforced here (`maxGuests`). Compiles + unit-tested
   (`DarwinRuntimeTests`, non-booting paths); a real boot needs Mac hardware.

   The container root and probes are now closed (see below); what is left in the
   seam is **interactive streamed exec** (`kubectl exec -it`) and **stats**, both
   noted at the end.
4. **Flip scheduling + remove the Machine path (done).** The `ferry-macos-vm`
   RuntimeClass now targets this Mac's own node (handler `ferry-macos-vm`,
   `nodeSelector ferry.dev/mode: vm-per-pod`, the toleration `ferry-vm` uses), so
   a plain `runtimeClassName: ferry-macos-vm` pod runs on the host via
   `DarwinRuntime` — no host-targeted class, no machines. The darwin **Machine**
   path is deleted: the `macos-vm` NodePool, the darwin code in ferry-karpenter
   (shapes, the 2-VM ceiling counter, the darwin Create path) and ferry-machined
   (`spec.os`/`spec.isolation`, the bundle clone, `--mac-image`, the single-use
   `ferry.dev/spent` taint) and the CRD's `os`/`isolation` fields. `ferry-cri`
   takes the golden image with `--mac-image` (`ferry up` passes it), and enforces
   the two-VM ceiling itself (`maxGuests`). The scheduler-level
   `ferry.dev/macos-guest` extended resource is a further polish; the ceiling is
   currently a `ferry-cri` backstop (a third macOS sandbox is refused).

## Container root and exec (closed)

- **Image → guest root (`DarwinImageStore.swift`).** ferry-cri runs on the host
  and already knows this Mac's registry (`--image-mirror`, the ferry-registry a
  machine node pulls from), so it fetches a `FROM macos` image's config and
  single layer over that registry's HTTP API host-side — no guest networking. On
  the first `StartContainer` the guest root is assembled: the baked OS base
  (`/private/var/ferry/darwin/os`, from `ferry-darwin -prepare`) is cloned in and
  the image layer is unpacked over it, so the workload's files have an OS to link
  against. The layer moves in over the agent as appended base64 chunks (the agent
  runs argv and reads no stdin, the same channel `ferry image build`'s COPY uses;
  BSD `tar` in the guest auto-detects gzip). The entrypoint then runs `chroot`ed
  into that root, with the image's and container's env and working directory
  merged the way CRI specifies.
- **Probes (`ExecSync`).** A liveness/readiness exec probe runs its command in
  the guest over the agent, `chroot`ed into the container root, and returns its
  output and exit status.

Still open (both need a real Mac to develop against, neither blocks a pod
running): **interactive streamed exec** (`kubectl exec -it`) needs the
SPDY/`ExecServer` path bridged onto the agent; and **stats** need guest-side
measurement (there are no cgroups), so `kubectl top` for a macOS pod reports
nothing for now.

## Hardware validation

`ferry-cri darwin-smoke <golden-bundle> [--chroot <root>] [--scriptfile <f>] [cmd...]`
boots a `DarwinSandbox` off the CRI path and runs a command in the guest — the
way this hardware-only path is exercised (a golden image and the virtualization
entitlement, which CI has neither).

**End-to-end, on an M-series Mac (macOS 26.6.2) against a baked `golden-node`:**
a `ferry-macos-vm` pod (via a host-targeted RuntimeClass — handler
`ferry-macos-vm`, `nodeSelector ferry.dev/mode: vm-per-pod`) ran through the real
kubelet → ferry-cri → `DarwinRuntime`: the image was fetched from the registry,
the root assembled (OS base + layer), the entrypoint ran chrooted, and the pod
**Succeeded (exit 0)** with its output in `kubectl logs`. Measured **~8–9s from
`kubectl apply` to Succeeded**, against ~17–35s for the Machine path — no second
Node, no in-guest kubelet.

Four things the first live run shook out (all now fixed): `ImageService` must
report a darwin image present with an id **and** a non-zero size (else the
kubelet fails at `ImageInspectError`); the image is fetched by
`user_specified_image`, not the digest the kubelet substitutes; the entrypoint
runs directly under `chroot` (the agent applies `WORKDIR` as a chdir on the real
FS before the chroot, so a shell wrapper fails); and the container run is awaited
(a detached `Task` dropped the exec once `StartContainer` returned).

The refinements the first runs left are now in, verified live on an M4 Max
(macOS 26.6.2): **`kubectl logs`** streams every line (output goes through a
per-line `ContainerLogWriter`, not a single append that prefixed only the first
line); **`WORKDIR`** is entered by a `cd <dir>; exec` shell inside the chroot
(macOS `chroot(8)` has no chdir flag) — a pod whose image sets `WORKDIR /src`
reports `cwd=/src`; **interactive streamed exec** (`kubectl exec`) runs in the
guest over the agent via the `ExecServer` bridge (stdin/TTY still not wired —
the agent runs argv with stdin from `/dev/null`); **stats** flow through CRI
`ContainerStats`/`ListContainerStats` (`ps`-measured guest RSS and cumulative
CPU, since there are no cgroups), so the kubelet summary reports CPU and memory;
and the **`ferry.dev/macos-guest`** ceiling is advertised on the node (capacity
2) with the RuntimeClass overhead charging 1, so a third macOS pod stays
Pending. Increment 4's scheduling flip (the `ferry-macos-vm` class targets the
host node) is also in.

Two things surfaced once a *long-running* macOS pod (not just a fast-exiting
one) was run, both now fixed:

- **`StartContainer` must not block for the life of the process.** The container
  run is streamed in a detached, tracked `Task` and the container is reported
  running immediately; awaiting it (the earlier log fix) would hang the kubelet
  and freeze the actor for every other pod.
- **A sandbox must report an IP or the kubelet kills it.** The guest is NAT'd
  behind the host with no routable address of its own (its `en0` gets no DHCP
  lease under `VZNATNetworkDeviceAttachment`), so `PodSandboxStatus` reports the
  **node's** address — the guest shares the host's network identity, as a
  host-network pod does. Without it the kubelet took the running sandbox for
  broken ("Sandbox for pod has no IP address") and tore it down seconds in.

## Cluster networking (pod-to-pod, DNS, Services)

A macOS pod now joins the cluster network, so it interoperates with every other
pod, resolves cluster DNS, and reaches ClusterIP Services.

- **Pod-to-pod.** The pod gets a second NIC (en1) on ferry's shared `PodSwitch`
  — a `SwitchInterface` (`VZFileHandleNetworkDeviceAttachment` over a socketpair),
  the same L2 fabric the Linux pods use — carrying a real cluster IP from a
  **dedicated /24 for this Mac's macOS pods** (counted down from 255 so it never
  overlaps a node slice, and sits outside the node's own vmnet /24 so every peer
  routes to it via the switch). en0 keeps NAT for the internet/default route.
  The root guest agent brings en1 up by the MAC we assigned it (no vminitd), and
  `PodSandboxStatus` reports the real cluster IP. Linux↔macOS and macOS↔macOS
  work, both directions, same node or across the relay.
- **Cluster DNS.** The guest's own resolver works; the fix was the *chroot* a
  container runs in. The `mDNSResponder` socket is hard-linked into the container
  root (at `/var/run` and `/private/var/run`) so a chrooted `getaddrinfo` reaches
  it, and an `/etc/resolver/<cluster-domain>` per cluster search domain points
  those names at CoreDNS over the switch (`scutil` injection breaks macOS 26's
  resolver, so a resolver file configd reads is used instead). External DNS,
  Service FQDNs and single-label (same-namespace) names resolve; multi-label
  short names (`svc.namespace`) need the FQDN — macOS won't append search domains
  to dotted names the way Linux ndots does.
- **ClusterIP Services.** A macOS pod has no in-guest kube-proxy, but its Service
  traffic transits ferry-cri's pod switch, so ferry-cri DNATs it host-side
  (`MacServiceNAT`): the pod routes the Service CIDR to a virtual gateway
  ferry-cri answers ARP for, a ClusterIP frame is rewritten to a chosen endpoint
  (L3 + checksum), and conntrack un-DNATs the replies. The ClusterIP→endpoint
  table is parsed from the same kube-proxy render ferry-cri already fetches for
  the Linux pods — no kubelet rebuild.

**Remaining (real) work:** stdin/TTY for interactive `exec -it`; and, for macOS
pods, NetworkPolicy, session affinity, SCTP and NodePort Services.

## Reusable building blocks (with paths)

- Clone: `clone()` in `ferry-macvm`/`experiments/*/macvm.swift`; `cp -cR`
  (clonefile) in `ferry-machined/reconcile.go`.
- Boot + network + config-share: `bootMac()` in
  `experiments/18-node-image/Sources/ferry-node/MacMachine.swift`.
- Guest agent (exec over vsock:7000): `experiments/39-macos-pods/agent.swift`
  (`ferry-macagent`), injected by `inject.sh`.
- Container engine: `experiments/39-macos-pods/ferry-darwin/` — `node.go`
  (`prepareOS`, the dyld/shared-cache OS base), `runtime.go`
  (`CreateContainer`/`StartContainer`, chroot exec, `-pod-vm` root),
  `images.go` (`PullImage`), `streaming.go`/`attach.go`/`stats.go`.
- Golden image contents: `experiments/39-macos-pods/bake-macos-node.sh` — the
  in-guest kubelet becomes dead weight under this model; the OS base,
  `ferry-darwin`, `ferry-macagent` and `podnet.dylib` stay.

## Risks

- The guest control channel is the main new surface: `ferry-macagent` is
  exec-only today. Attach/logs/stats/stdin need adding, or `ferry-darwin`'s
  streaming server is bridged to the host.
- `ferry-darwin` currently assumes it is the node's CRI (pod-CIDR, Services, NFS
  volumes via the in-guest kubelet). Driven as a host sandbox it keeps the
  container-run parts and drops the node-networking parts; the split needs care.
- Everything VM-boot is Mac-hardware- and entitlement-bound, so increment 2 is
  not CI-verifiable and must be exercised on a real Mac.
