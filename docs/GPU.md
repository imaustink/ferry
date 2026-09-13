# GPU on ferry

**Status: built. A scheduled pod runs work on the Mac's GPU.**

```
$ kubectl logs gpu-demo -c app
device: Apple M4 Max (applegpu_g16s), 110100 MiB
matmul: 9406 GFLOP/s in 0.037s (checksum 629.3843)
generated in 0.76s: Graphics rendering and parallel processing.

$ kubectl exec gpu-demo -c sidecar -- ls /run/ferry/
ls: /run/ferry/: No such file or directory
```

An ordinary pod, asking for `ferry.dev/gpu: 1` in its manifest, doing 9.4
TFLOP/s of Metal arithmetic and a round of on-device text generation -- through
a unix socket relayed into its VM over vsock. The sidecar in the same VM, which
did not ask, does not even have the directory.

The rest of the loop holds too. A second pod requesting the GPU while the first
holds it stays Pending on `Insufficient ferry.dev/gpu`, from the scheduler, with
no device plugin anywhere. Delete the first and the second starts within
seconds and uses the GPU itself.

What is designed here is not pass-through. It cannot be: `Virtualization.framework`
exposes no PCI passthrough, no VFIO, and no GPU compute device of any kind, and
Apple silicon has no discrete GPU to hand over even if it did. The whole
framework mentions the GPU once, in a doc comment on
`VZVirtioGraphicsDeviceConfiguration`, describing a paravirtualised *display*
for drawing in a `VZVirtualMachineView`. USB passthrough exists since macOS 15,
but `VZUSBDeviceConfiguration`'s only conformer is mass storage.

The Mac's GPU is reachable through exactly one door: Metal, in a macOS process.
ferry already has a macOS process next to every pod. So the GPU does not move
into the pod -- the work moves out to the host, over a socket, and the pod
never learns there was a hypervisor in the way.

## The shape

```
  pod VM                                  macOS
  ┌───────────────────────────┐
  │ container                 │
  │   /run/ferry/gpu.sock ────┼── vsock ──▶ /tmp/ferry-run/gpu/<uid>.sock
  │                           │                      │
  └───────────────────────────┘                 ferry-gpud
                                                     │
                                                   Metal
```

A pod that asks for `ferry.dev/gpu` gets one extra file in its filesystem: a
unix socket. Behind it, on the Mac, is `ferry-gpud` holding the GPU. Nothing
else about the pod changes -- no device node, no privileged mode, no host
network.

## The transport is already built

This is the part that would normally be the work, and it is not. Apple's
Containerization framework ships a vsock-backed unix socket relay, and
`LinuxPod` takes it per container:

```swift
// LinuxPod.ContainerConfiguration
public var sockets: [UnixSocketConfiguration] = []
```

`UnixSocketConfiguration(source:destination:permissions:direction:)` with
`direction: .into` takes a socket path on the host and makes it a socket path
inside the guest. The relay runs over the pod's existing vsock device --
`Vminitd: SocketRelayAgent` (`Vminitd+SocketRelay.swift:17`) is the guest end,
`UnixSocketRelayManager` the host end, and `LinuxPod.relayUnixSocket` allocates
the port and starts both.

Two details worth knowing, both from `LinuxPod.swift`:

- The socket is staged **outside** the rootfs, at `/run/sockets/<id>.sock`, and
  bind-mounted to the destination when the container starts -- deliberately, to
  avoid symlink traversal and mount shadowing. The pod cannot reach around it.
- `relayUnixSocket(_ containerID:socket:)` is public and works on a created pod,
  so a relay can be added after boot. This is the one device-shaped thing on
  ferry that is **not** frozen at boot -- unlike containers, which are.

There is no guest kernel change, no new binary in the guest, and no new
transport code on either side.

Experiment 08 confirms all of it end to end: a socket on the Mac appears in the
container, bytes round-trip, the destination path is created however deep it is,
and a second container in the same pod that asked for nothing finds *nothing* at
that path. The last one matters most -- containers in a pod share a kernel and a
network stack, so per-container scoping was not obvious, and the design assumes
a sidecar does not inherit the GPU its neighbour was granted.

## Why vsock and not the pod network

Pod addresses are routable from the Mac, so `ferry-gpud` could just as well
listen on the pod gateway and be reached over TCP. vsock wins on one argument
that matters more than convenience:

**Identity is free.** The relay is set up per container, on a port allocated for
that VM. When `ferry-gpud` accepts a connection it already knows which pod is
calling, because there is only one pod that socket could have come from. Over
TCP the answer is a source address, which is a claim, and the GPU service would
need an authentication protocol and a story about what happens when a pod picks
up a recycled address. Over vsock there is nothing to authenticate.

Second: a service on the pod gateway is reachable by **every** pod, whether or
not it asked for a GPU. The relay is reachable only by the pods ferry gave it
to. Gating happens at pod creation rather than in the service.

The honest cost: **vsock is not covered by NetworkPolicy.** A pod with
deny-all egress still reaches `ferry-gpud`, because the relay is not on the pod
network at all. That is the correct behaviour for a device -- a NetworkPolicy
does not stop a pod using its GPU on any other cluster either -- but it means
the resource request is the only gate, so it has to actually hold.

## Getting the request to the runtime

CRI has no field for extended resources. `ContainerConfig.Linux.Resources`
carries CPU, memory and cgroup settings; `ferry.dev/gpu` appears nowhere in the
CRI contract, so the runtime has to be told some other way.

ferry already has the mechanism. `ferry-cri` asks `ferry-streamer` what a pod
contains, on every pod, because CRI never says how many containers to expect
(`podlookup.go:44`, `PodRuntime.swift:384`). That endpoint has the real pod spec
in hand and currently throws all of it away but the names:

```go
type podContainers struct {
	InitContainers []string `json:"initContainers"`
	Containers     []string `json:"containers"`
	GPUContainers  []string `json:"gpuContainers"`   // <- containers requesting ferry.dev/gpu
}
```

One loop over `c.Resources.Limits` in a handler ferry already calls. No
annotations, no new round trip, and the source of truth stays the pod spec.

## The seams

Four, and none of them large. The daemon was the work.

| change | where |
|---|---|
| report which containers request `ferry.dev/gpu` | `ferry-streamer/podlookup.go` |
| decode it, grant the socket, hand it back on stop | `ferry-cri/.../PodRuntime.swift`, `GPUClient.swift` |
| attach the relay to the container | `PodRuntime.swift`, in the `addContainer` closure |
| start the daemon, advertise capacity | `ferry` |

The `addContainer` seam is what the whole design comes down to, sitting next to
the mounts that were already appended there:

```swift
if let gpuSocket {
    c.sockets.append(UnixSocketConfiguration(
        source: URL(filePath: gpuSocket),
        destination: URL(filePath: GPUClient.guestPath),
        direction: .into))
}
```

### Node capacity needs no kubelet patch

Extended resources survive on the node without a device plugin. The kubelet's
capacity setter is explicit about it:

```go
// Note: avoid blindly overwriting the capacity in case opaque
//       resources are being advertised.
if node.Status.Capacity == nil {
```

It merges into `node.Status.Capacity` rather than replacing it, and only zeroes
resources a device plugin previously registered and then withdrew
(`pkg/kubelet/nodestatus/setters.go:204-283`). So a `PATCH` of
`status.capacity["ferry.dev/gpu"]` at `ferry up` sticks, the scheduler gates on
it, and `darwinContainerManager` -- which wraps `NewStubContainerManager()` and
has no device manager -- stays as it is.

This is worth stating plainly because it is the opposite of what the device
plugin documentation implies: ferry does not need to implement the device
plugin API to have a schedulable GPU resource. It needs one PATCH.

What capacity to advertise is a policy question, not a discovery one. There is
one GPU. The number is how many pods may hold a relay at once, and `1` is the
defensible starting value: Metal will happily accept work from ten pods and
serve all of them badly.

## What is on the other end

`ferry-gpud` holds the GPU and serves HTTP over the socket. It has no
dependencies: Metal, MPS and the on-device model are all in the OS, so there is
no package graph to fetch and no weights to ship before a pod can use it.

| | |
|---|---|
| `GET /v1/device` | what the GPU is -- name, architecture, unified memory, limits |
| `GET /v1/model` | whether the on-device model is usable, and why not if it is not |
| `POST /v1/matmul` | a square matrix multiply on the GPU, `{size, iterations}` |
| `POST /v1/generate` | text generation on the on-device model, `{prompt, instructions, temperature, maxTokens}` |

`matmul` is not a demo of the protocol -- it is the thing that proves, from
inside a pod, that the Mac's GPU did arithmetic the pod asked for. It returns
GFLOP/s and a checksum over fixed inputs, so a caller can tell that work
happened rather than that time passed.

`generate` is the on-device model macOS 26 ships, which is why it is the first
inference backend rather than MLX or llama.cpp: nothing to download. Those can
sit behind the same endpoint later without the pod noticing, which is the point
of putting a protocol here rather than a device.

Work is serialized on one device -- Metal will accept work from ten pods at
once and serve all of them badly, and the timings would stop meaning anything.
Each generation gets a fresh session: pods do not share a conversation, and a
transcript accumulating across tenants would be a leak rather than a feature.

### The control socket

A second socket, ferry-cri's rather than a pod's, mints the per-pod ones:

```sh
curl --unix-socket /tmp/ferry-gpud.sock -XPOST http://l/pods \
  -d '{"uid":"<pod uid>","namespace":"default","name":"demo"}'
# -> {"socket": "/tmp/ferry-run/gpu/<pod uid>.sock", ...}
```

`POST /pods` is idempotent, because the kubelet retries and two containers in
one pod may both have asked; a retry must not cost a second slot. `DELETE
/pods/<uid>` hands the slot back, and `GET /pods` shows who holds one and how
many requests they have made -- the accounting that `kubectl top` will never
show.

Over capacity is a 409, and `ferry-cri` fails CreateContainer rather than
starting a pod without the socket it asked for: a pod that requested a GPU and
silently did not get one fails much later and much more confusingly, as a
missing file, long after the scheduler charged the node for it.

### The shim, if it is wanted

A unix socket is awkward for clients that only speak TCP. The fix is the
pattern ferry already uses for `nft`: a small static binary, mounted in with its
own loader so the base image is irrelevant, listening on `127.0.0.1:<port>` and
forwarding to `/run/ferry/gpu.sock`. Containers in a pod share a network stack,
so one shim serves the whole pod.

Not built -- `curl --unix-socket` and most HTTP libraries handle a unix socket
directly, including Python's `http.client` with a four-line subclass -- but it
is what would turn "a socket ferry gave you" into "an endpoint your SDK already
reaches".

## What this is not

Worth writing down, because the name invites the wrong expectation:

- **Not CUDA.** Nothing that links `libcuda` runs. No `/dev/nvidia*`,
  no `nvidia-smi`, no NVIDIA device plugin, no GPU Operator.
- **Not a device.** `nvidia.com/gpu` in a manifest means nothing here; the
  resource is `ferry.dev/gpu` and the semantics are "a relay to the host",
  not "a card".
- **Not general.** A workload gets the GPU only through whatever protocol
  `ferry-gpud` speaks. Arbitrary GPU code in a pod has no path to the hardware
  and will not acquire one while `Virtualization.framework` looks like this.
- **Not isolated.** One Metal device, shared. There is no MIG, no time-slicing
  guarantee, and a pod that saturates the GPU degrades every other pod holding
  a relay. Capacity `1` is the isolation story.

## Using it

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-demo
spec:
  containers:
    - name: app
      image: python:3.12-alpine
      resources:
        limits:
          ferry.dev/gpu: 1
```

The socket appears at `/run/ferry/gpu.sock`. From inside the pod:

```sh
curl --unix-socket /run/ferry/gpu.sock http://l/v1/device
curl --unix-socket /run/ferry/gpu.sock -XPOST http://l/v1/matmul -d '{"size":2048,"iterations":20}'
curl --unix-socket /run/ferry/gpu.sock -XPOST http://l/v1/generate -d '{"prompt":"hello"}'
```

`FERRY_GPU_CAPACITY` sets how many pods may hold it at once; the default is 1.
A pod that asks when the node is full stays Pending, which is the scheduler
doing its job.

### More than one node

`ferry join` brings up another Mac, which has a GPU of its own: it starts its
own daemon and advertises its own capacity.

`ferry node add` is different -- another node on *this* Mac, sharing the one
GPU. Those nodes reach the same daemon, but do not advertise capacity of their
own: two nodes each claiming `ferry.dev/gpu: 1` would tell the cluster there are
two GPUs when there is one. In practice GPU pods land on node 0.

### Who can reach it

The socket directory is `0700` and each pod socket `0600`. The only thing that
opens them on the host is ferry-cri's relay, running as the same user, so
nothing is lost by closing them -- and on a shared Mac it means another local
account cannot dial a pod's GPU socket directly.

Inside the pod it is the opposite, and deliberately: any process in that
container can use the socket. It has already been granted the GPU; the container
boundary is the gate, not the file mode.

## Open questions

- **Lifecycle.** The socket is handed back when the pod stops rather than when
  it is removed -- a stopped pod is not using the GPU and should not hold the
  node's only slot. What happens to *in-flight* work when a pod is deleted
  mid-request is still unanswered, and matters more as capacity rises above 1.
- **Accounting.** `GET /pods` counts requests per pod, which is better than
  nothing and less than useful. Nothing reports GPU time to the node or the
  pod, and `kubectl top` will never show it.
- **Fairness.** Work is serialized, so a pod that submits a long job delays the
  next one -- no preemption, no queue limit. At capacity 1 this is barely
  visible; it is the first thing that breaks when it is raised.
- **Memory.** Nothing bounds how much of the GPU's unified memory a request may
  ask for beyond `maxBufferLength`, and the allocation is the host's rather
  than the pod's, so it is not charged against the pod's own limit.
- **Capacity is advertised once, at `ferry up`.** It is withdrawn at `ferry
  down`. If the node object is deleted and recreated while ferry is running, the
  capacity goes with it and nothing puts it back until the next restart.
- **The `.outOf` direction** remains unexplored, and is the interesting inverse:
  a pod exposing a socket onto the Mac.

## Next step

The obvious one is another backend behind `/v1/generate` -- MLX or llama.cpp
with real weights, for a model larger than the one the OS ships. The endpoint
was shaped so that lands without the pod noticing.

The one that would change the design is **capacity above 1**, which needs the
fairness and lifecycle answers above before it is anything but a way to make
every pod slower at once.
