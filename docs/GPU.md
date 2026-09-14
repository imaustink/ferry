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
| `POST /v1/generate` | text generation on the on-device model, `{prompt, instructions, temperature, maxTokens}`; reports how often it yielded |
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

### Two lanes, because the Mac has two answers

"The GPU" turned out to be the wrong unit. Measured on this M4 Max
([experiment 12](../experiments/12-gpu-contention/FINDINGS.md)):

```
two matmuls        one alone 12768 GFLOP/s
                   two at once 6505 + 6424 = 12930 (101% of one)

matmul + generation   matmul -0.9%, generation -12.0% per character
```

Two Metal matmuls split one GPU and the total does not move, so running them at
once buys one percent and makes both of them half as fast. A matmul and a
generation ignore each other entirely -- Apple's model does not run on the
shaders, and the Neural Engine is separate silicon.

So there is a lane per unit rather than one token for the machine: **compute**
for Metal work, serialised, and **model** for the on-device model, independent.
Within a lane everything below applies. Across lanes, nothing does: a pod
generating text and a pod multiplying matrices never wait for each other,
because the hardware does not make them.

What a small matmul waits for, through the daemon:

```
nothing else running                         0.096s 0.083s 0.083s
a generation running (other lane)            0.104s 0.086s 0.087s   <- no wait
another matmul running (same lane)           0.098s 0.580s 0.579s   <- the slice
```

That middle row used to cost 0.26-0.77s. It is now indistinguishable from an
idle machine, and the generation is not interrupted at all -- it reports zero
yields, because nothing needs it to step aside.

`GET /capacity` and `/metrics` report what is queued per lane, which is the
number that says *which* resource is short rather than that something is.

### Sharing a lane

One lane, many pods, so something has to decide the order -- and a plain lock
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

**Generation yields too**, which is not obvious, because a generation looks
opaque: hand over a prompt, wait, get a paragraph. It is not, if it is streamed.
The model emits snapshots as it goes -- measured on this one, a 5s generation
arrives as 27 snapshots a median of 0.153s apart -- and the gap between them is
a checkpoint as good as the gap between matmul passes.

So `/v1/generate` streams internally even though nothing shows partial output to
anyone. It is streamed for the checkpoint. A matmul asking while a 4.6s
generation runs:

```
with the generation yielding      0.26s  0.65s  0.61s  0.77s
with it holding the device        3.37s  0.08s  0.08s  0.08s   <- waited it out
```

The second row is the same test with the slice raised past the generation's run
time, which is what the old behaviour was: the first matmul waits for the whole
generation, and the rest are fast only because there is nothing left to wait
for. Streaming costs the generation nothing beyond the time it hands over.

It buys two other things that were previously impossible. A generation can now
be **cancelled** when its pod goes away -- 499 within a snapshot of the pod being
deleted, rather than after the whole paragraph -- and its **deadline** is checked
per snapshot rather than only at the end.

What **cannot** be preempted is a single Metal command buffer, which runs to
completion whatever anyone wants. That is the real floor on how long a co-tenant
waits -- one pass of whatever is running, which at the largest allowed matmul is
about 0.9s -- and it is why size is capped as well as time.

The slice is 0.5s by default (`FERRY_GPU_SLICE`), which is roughly the worst
wait a co-tenant sees. It was picked by measuring rather than taste: at 2s a
waiting pod waited 2.1s, at 0.5s it waited 0.6s, and the hog's own time on the
device did not measurably change.

### Not every turn is worth the same

Kubernetes already has the word for this. `PriorityClass` is a first-class API,
and the admission plugin resolves `priorityClassName` into `spec.priority` on
every pod -- 0 when nobody said otherwise. ferry already reads the pod spec to
find the GPU request, so priority comes along beside it and needs nothing new
invented.

A pod that outranks the holder does not wait out its slice: the holder yields at
its next checkpoint, which is one command buffer away. Measured, with the same
hog and the same waiter, changing only the priorities:

| waiter against the hog | four consecutive waits |
|---|---|
| outranks it (100000 vs 0) | 0.11s 0.10s 0.10s 0.10s |
| same priority (0 vs 0) | 0.10s 0.64s 0.59s 0.60s |
| outranked by it (0 vs 100000) | 5.20s 5.16s 5.18s 5.16s |

Strict priority starves, so it is bounded. Anything that has waited longer than
the starvation guard -- 5s by default -- goes next whatever anyone's priority,
which is the third row: served last, but served. **Priority decides who goes
first, not who goes at all.**

The rescue has to be protected to mean anything. A pod let in by the guard would
otherwise hit its first checkpoint, see the pod that outranks it still waiting,
and hand the device straight back without doing any work -- admitted by the
guard and evicted by priority, forever. So a pod rescued *from a pod that
outranks it* keeps the device for its slice. A pod that merely waited a long
time on a busy device is not rescued from anyone and gets no protection, or a
high-priority arrival would be delayed a slice for nothing.

**Every request has a deadline**, queue time included -- a client that asked for
120s means 120s, not 120s once it is its turn. Verified both while running (504
at 5.00s against a 5s budget) and while queued.

**A deleted pod takes its work with it.** Revoking a grant cancels that pod's
queued *and* running requests, and the caller gets a 499 rather than waiting.

**The queue is bounded** -- 64 waiting by default, 8 from any one pod -- and a
full queue is a 503 rather than an unbounded backlog.

Each lane also bounds how big one request may be, and they need different
bounds because they consume different things. A compute request may allocate at
most a quarter of the GPU's recommended working set: unified memory is shared
with the whole Mac and the allocation is the host's, so an unbounded one is a
denial of service against the Mac rather than against the pod. A model request
is capped at 4096 response tokens, which is the same idea for the thing the
model actually spends -- `maximumResponseTokens` previously went to the
framework exactly as the pod sent it, so "as long as it likes" was the policy.

| flag | default | |
|---|---|---|
| `--capacity` | 1 | pods that may hold a socket at once |
| `--time-slice` | 0.5 | seconds before a waiting pod gets a turn |
| `--starvation-guard` | 5 | seconds before it gets one regardless of priority |
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

- **One pass is the floor, in the compute lane.** A co-tenant's worst wait there
  is the time slice plus whatever command buffer is already running, and the
  second half of that is not ours to interrupt. At the largest allowed matmul it
  is about 0.9s.
- **Two lanes because two were measured.** A third kind of work -- a Core ML
  model, a video encode, a matmul too small to fill the GPU -- would need its own
  measurement before anyone could say which lane it belongs in. The lane is a
  claim about hardware, not a label.
- **The `.outOf` direction** remains unexplored, and is the interesting inverse:
  a pod exposing a socket onto the Mac.

## Next step

Another backend behind `/v1/generate` -- MLX or llama.cpp with real weights, for
a model larger than the one the OS ships. The endpoint was shaped so that lands
without the pod noticing, and the yielding is already solved for it: a token
loop has the same checkpoint between tokens that the stream gives us here.
