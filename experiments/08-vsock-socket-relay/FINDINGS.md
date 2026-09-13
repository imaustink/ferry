# 08 — a unix socket from the Mac into a pod

**A host socket reaches a process inside the pod VM, over vsock, scoped to the
container that asked for it. The pod has no network interface at all.**

```
==> booting
    booted in 0.23s
    host <- guest: "ferry"
    guest: sent ferry, got FERRY
    side: sidecar sees /run/ferry/gpu.sock: False (absent)
    side: sidecar connect: refused: FileNotFoundError
==> result
    guest reached the host socket : yes
    guest saw the host's answer   : yes
    container exit code           : 0
    sidecar was denied the socket : yes

PASS: gpu.sock on the Mac is /run/ferry/gpu.sock in the pod,
      and only in the container that asked for it
```

## Why this was asked

Every device-shaped thing on ferry is frozen at boot, because
`Virtualization.framework` cannot hotplug. [docs/GPU.md](../../docs/GPU.md)
proposes the one exception: a socket relay, carried over the pod's existing
vsock device, as the way a pod reaches something only macOS can do -- Metal
being the case that prompted it, since there is no GPU pass-through on Apple
silicon and never has been.

The whole design rests on a relay that nothing in ferry uses yet. So: does it
carry bytes, and is it scoped?

The host end upper-cases what it is given. `ferry` goes in, `FERRY` comes back,
and only this process can produce capitals -- an echo that returned `ferry`
would prove nothing.

## What it takes

Nothing. The relay is Containerization's, not ferry's:

```swift
c.sockets = [UnixSocketConfiguration(
    source: hostSocket,                              // on the Mac
    destination: URL(filePath: "/run/ferry/gpu.sock"), // in the container
    direction: .into)]
```

One property on `LinuxPod.ContainerConfiguration`. No guest kernel change, no
binary in the guest, no transport code on either side. `Vminitd: SocketRelayAgent`
is the guest end and `UnixSocketRelayManager` the host end, both already shipped.

## Findings

**It works, and it is fast.** Round trip verified through two containers and a
VM boot of 0.21–0.28s across runs -- the relay adds nothing measurable to boot.

**It owes nothing to the pod network.** The pod is configured with
`interfaces = []` -- no vmnet, no cluster segment, no address of any kind -- and
the socket still works. This is the argument for the relay over a TCP listener
on the pod gateway: the transport is not on the pod network, so it cannot be
reached by pods that were not given it, and cannot break when the network moves.
The cost, unchanged from the design: NetworkPolicy does not see it either.

**It is scoped to the container, not the pod.** A second container in the same
VM, with no socket configured, finds nothing at the path -- confirmed as
`absent`, not merely refused. Containers in a pod share a kernel and a network
stack, so this was not obvious, and the design depends on it: a pod's sidecar
does not inherit the GPU its main container was granted.

**The guest creates the destination, however deep.** `/run/ferry/gpu.sock` does
not exist in the image; neither does `/opt/ferry/a/b/c/gpu.sock`, which also
worked. Nothing has to prepare a mount point, so ferry can pick any path.

**The socket is staged outside the rootfs.** `LinuxPod` puts it at
`/run/sockets/<id>.sock` and bind-mounts it in, deliberately, against symlink
traversal and mount shadowing (`LinuxPod.swift:899`). The pod cannot reach
around it.

## The one that cost time

The first run of the sidecar check reported `True` — it could see
`/run/ferry/gpu.sock`, which read as the relay leaking across containers in the
pod and would have sunk the design.

It was not a leak. The inode was a **regular file**, not a socket, and
connecting got `ConnectionRefusedError`. It was a stale mount point: creating a
bind mount's destination writes into the container's root filesystem, and this
probe had handed the probe container the *cached unpacked image* rather than a
clone of it. So run 1's container left `/run/ferry/gpu.sock` behind in the
shared image, and the sidecar's clone in run 2 inherited an empty file at
exactly the path under test.

Two things worth keeping:

- **Clone per container, always.** `ferry-cri` already does
  (`PodRuntime.swift:727`); this probe reproduced, in about twenty lines, the
  reason that line exists. A container mutates its rootfs merely by having
  mounts.
- **"Exists" is not the test.** The check now reports the inode type and the
  result of connecting, so a leak and a leftover cannot be confused again. The
  verdict requires `absent`: a path that exists but refuses a connection is
  still a mount point somebody can inherit.

## The same relay, with a GPU behind it

`--gpu-socket <path>` relays a real `ferry-gpud` pod socket instead of this
probe's echo server, and the guest asks for work rather than for capitals:

```
==> relay probe (ferry-gpud)
    booted in 0.26s
    guest: device: Apple M4 Max (applegpu_g16s)
    guest: matmul: 2048x2048 x20 -> 7406 GFLOP/s in 0.046s (checksum 629.3843)
    guest: generated in 1.32s: A VM per pod is unusual because it is more common
           to use a containerized environment for pods, ...
    side: sidecar sees /run/ferry/gpu.sock: False (absent)
```

Same pod with no network interface, same relay, same per-container scoping --
the only difference is what is listening on the Mac. `ferry-gpud` knows nothing
about VMs, vsock or this probe: it binds a unix socket, and ferry decides who
reaches it. The checksum matches a run made directly on the host, so the
arithmetic crossing the boundary is the arithmetic that came back.

## What this does not show

- **One connection at a time.** No concurrency, no contention between pods, no
  throughput number for large transfers. If a protocol moves tensors rather
  than JSON, the relay's bandwidth is an open question this does not touch.
- **Nothing about lifecycle.** The relay is torn down with the pod here.
  In-flight work when a pod is deleted mid-request remains an open question in
  [docs/GPU.md](../../docs/GPU.md).

## Running it

```sh
./build.sh
./relayprobe --kernel ../03-vm-ceiling/assets/vmlinux-arm64
```

`--destination` moves the path inside the container, `--image` changes the guest
(it needs an `AF_UNIX` client; busybox `nc` cannot do unix sockets, which is why
the default is python). The build is ad-hoc signed for
`com.apple.security.virtualization`; no vmnet entitlement is needed, because the
pod has no network.
