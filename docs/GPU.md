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

Both arguments got stronger when the Mac joined the pod network
([docs/POD-NETWORK.md](POD-NETWORK.md)). A host listener there is now plainly
reachable from every pod in the cluster, so "only the pods that asked" would
have to be enforced by the service itself, on a source address, forever.

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

That one patch is the start of it, not the whole story: ferry-streamer then
keeps the resource matching the daemon, so the node stops advertising a GPU it
cannot actually serve. See **When things die**.

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
| `GET /v1/usage` | this pod's own accounting, and no one else's |

The control socket adds `/capacity`, `/pods`, `/stats` and `/metrics`.

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
/pods/<uid>` hands the slot back and cancels anything that pod had in flight.
`GET /pods` shows who holds one, `GET /capacity` how much is left and how deep
the queue is, and `GET /stats` what every pod has cost.

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

## Sharing it

One GPU, many pods, so something has to decide the order -- and a plain lock
decides it badly. `ferry-gpud` hands out a device token behind a queue that is
bounded, fair, deadlined, preemptible and cancellable.

**Fair across pods, not across requests.** The queue rotates over pods rather
than running first-come-first-served, because FIFO is fair to *requests* and
that is not the same thing: ten queued jobs from one pod would push everyone
else behind all ten. Measured, with a pod that filled its queue before a second
pod asked for anything at all:

```
a1 finished at +2.26s     a1, a2 and a3 were all submitted
a2 finished at +4.51s     before b1 was
b1 finished at +6.76s  <- b overtakes a's backlog
a3 finished at +9.04s
```

**Preemptible**, which is what ordering alone cannot give you. A queue only
helps when jobs are short: one 30-second matmul makes every other pod wait 30
seconds however fair the order is. So a request holding the device gives it up
at a checkpoint once its slice is spent and another pod is waiting, and picks up
where it left off. Two pods, one submitting ~35 seconds of work and the other
asking for a fraction of a second:

```
quick round 1: waited 0.1s for 5 passes
quick round 2: waited 0.6s for 5 passes     <- while the hog held 35s of work
quick round 3: waited 0.6s for 5 passes
quick round 4: waited 0.6s for 5 passes
hog   round 1: waited 35.4s for 3000 passes
```

The work runs on the caller's own thread, so a job's progress is just that
thread's stack: handing the device over and taking it back costs nothing but the
handoff. Nothing is re-run and no progress is serialised anywhere.

What **cannot** be preempted is a single Metal command buffer, which runs to
completion whatever anyone wants. That is the real floor on how long a co-tenant
waits -- one pass of whatever is running, which at the largest allowed matmul is
about 0.9s -- and it is why size is capped as well as time.

The slice is 0.5s by default (`FERRY_GPU_SLICE`), which is roughly the worst
wait a co-tenant sees. It was picked by measuring rather than taste: at 2s a
waiting pod waited 2.1s, at 0.5s it waited 0.6s, and the hog's own time on the
device did not measurably change.

**Every request has a deadline**, queue time included -- a client that asked for
120s means 120s, not 120s once it is its turn. Verified both while running (504
at 5.00s against a 5s budget) and while queued.

**A deleted pod takes its work with it.** Revoking a grant cancels that pod's
queued *and* running requests, and the caller gets a 499 rather than waiting.

**The queue is bounded** -- 64 waiting by default, 8 from any one pod -- and a
full queue is a 503 rather than an unbounded backlog. A request may allocate at
most a quarter of the GPU's recommended working set; unified memory is shared
with the whole Mac and the allocation is the host's, so an unbounded one is a
denial of service against the Mac rather than against the pod.

| flag | default | |
|---|---|---|
| `--capacity` | 1 | pods that may hold a socket at once |
| `--time-slice` | 0.5 | seconds before a waiting pod gets a turn |
| `--request-timeout` | 120 | seconds per request, queue time included |
| `--queue-depth` | 64 | requests waiting for the device |
| `--pod-queue-depth` | 8 | of those, from any one pod |
| `--memory-fraction` | 0.25 | of the working set, per request |
| `--drain-timeout` | 10 | seconds to finish in-flight work on the way down |

### More than one pod at a time

`FERRY_GPU_CAPACITY` above 1 is a supported configuration rather than a
theoretical one: preemption, fair queueing and deadlines are what it was waiting
on. It does not make the Mac faster -- it lets more pods share one device, each
of them slower, with a bounded wait. The numbers above were measured at
capacity 2.

## Accounting

Per pod: requests, failures, seconds on the device, seconds spent waiting for it,
and how often its work was preempted for someone else.

```
$ kubectl get pods -o custom-columns='NAME:.metadata.name,\
    GPU-SEC:.metadata.annotations.ferry\.dev/gpu-seconds,\
    QUEUED:.metadata.annotations.ferry\.dev/gpu-queued-seconds'
NAME        GPU-SEC   QUEUED
gpu-hog     35.1      0.3
gpu-quick   0.3       1.5
```

`ferry-streamer` writes those onto the pod, because `kubectl top` will never
show them -- it reads the kubelet's summary API, which knows about CPU and
memory and nothing else. The pod object is the nearest place the cluster can
see. Writes only happen when a value actually moves, so an idle pod costs
nothing; a node credential that is not allowed to annotate pods logs once and
stops trying.

The same numbers are on the control socket at `GET /stats`, as Prometheus text
at `GET /metrics`, and a pod can read its own -- and only its own -- at
`GET /v1/usage`.

The queue-wait number is the one worth watching: it says whether `--capacity` is
set higher than what these pods actually do.

## When things die

**The daemon.** Grants are written to `grants.json` beside the sockets and
restored on startup, so a daemon that crashes or is restarted re-binds the same
socket paths. The relay dials on demand, so a pod that was running throughout
simply works again -- verified by SIGKILLing the daemon under a live pod, which
kept its GPU without restarting. `ferry up` deletes that file, because there the
pods really are gone.

**Two daemons.** Starting a second one on a live socket is refused rather than
silently taking it over, which would leave half the pods talking to one process
and half to the other. A socket with nothing behind it is still cleared, so a
crash does not block the next start.

**A pod that went away while the daemon was down.** Restoring grants would
otherwise re-bind a socket for a pod that no longer exists, and nothing would
ever release it -- the node's only slot, held by a ghost. ferry-cri cannot fix
this, since its own view of sandboxes does not survive a restart either. The API
server knows, so `ferry-streamer` revokes any grant older than a minute whose
pod is gone or finished:

```
gpu: revoked default/ghost -- its pod is gone
```

**The capacity.** `ferry-streamer` asks the daemon what it will serve every ten
seconds and keeps `ferry.dev/gpu` matching the answer. That covers the two ways
the node ends up lying: a Node object recreated without the resource, and a
daemon that died while the node kept advertising a GPU. Three consecutive failed
probes withdraw it -- enough tolerance that restarting the daemon by hand does
not flap the node, little enough that a dead one is noticed:

```
t+20s: ferry.dev/gpu appears 3 time(s)
t+30s: ferry.dev/gpu appears 0 time(s)   <- daemon killed, resource withdrawn
```

Pods then stay Pending, which is the correct way to be out of GPUs. Restart the
daemon and it is back within a tick.

## Open questions

- **One pass is the floor.** A co-tenant's worst wait is the time slice plus
  whatever command buffer is already running, and the second half of that is not
  ours to interrupt. At the largest allowed matmul it is about 0.9s.
- **Generation cannot yield.** `/v1/generate` is opaque to us once the model has
  the prompt, so it holds the device for its whole run and is bounded only by the
  request deadline. A matmul submitted alongside waits for it.
- **Nothing is priority-aware.** Every pod's turn is worth the same. There is no
  way to say that one workload matters more, and Kubernetes has no standard way
  to express it for an extended resource either.
- **The `.outOf` direction** remains unexplored, and is the interesting inverse:
  a pod exposing a socket onto the Mac.

## Next step

Another backend behind `/v1/generate` -- MLX or llama.cpp with real weights, for
a model larger than the one the OS ships. The endpoint was shaped so that lands
without the pod noticing, and it is also where the yielding question gets
interesting: a token loop has an obvious checkpoint between tokens, which the
system model's API does not give us.
