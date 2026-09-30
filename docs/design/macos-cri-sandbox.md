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

   Still open within this seam, both needing a golden image to develop against:
   **the container root** (a `FROM macos` image's files plus the guest's baked OS
   base assembled under a `chroot` — today the command runs against the guest's
   own filesystem), and **exec/stats parity** (exec into a macOS pod currently
   errors clearly rather than running).
4. **Flip scheduling + remove the Machine path.** Repoint the RuntimeClass to the
   host node (mirror `ferry-vm`'s `ferry.dev/mode: vm-per-pod`), advertise
   `ferry.dev/macos-guest`, and delete the darwin code in ferry-karpenter and
   ferry-machined and the `macos-vm` NodePool. Do this only once increment 3 runs
   on hardware, so macOS pods never regress.

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
