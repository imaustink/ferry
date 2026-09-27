# A loaded image on every node, and a chown that holds in mode 2

Three gaps from the architectural list, taken in order:

1. **An image was loaded per node.** `ferry image load` put an image into one
   ferry-cri's store. A pod on a second node on the same Mac, on another Mac,
   or on a machine unless `FERRY_MACHINE_REGISTRY=1` was set, never found it.
   **Closed**, measured below on one Mac with a second Mac simulated.
2. **`chown` in mode 2, and ReadWriteOnce there.** A machine cannot take a
   device after boot, so every claim on one was a directory in the virtiofs
   share. **Closed for single-writer claims, as an opt-in class**:
   `ferry-local-block` is an ext4 image attached over USB to the machine the
   pod lands on. Measured end to end.
3. **RWX chown and cross-Mac volumes.** An unprivileged NFSv3 server on the
   Mac was **spiked and measured, not built** as a class. It mounts, chowns and
   writes from both modes, at the share's speed. What it would take to ship is
   at the end.

All of it was run on one M4 Max, macOS 26.6.2, a worktree cluster (profile
`agent-aec6def78f126a349`, pod network 10.172.0.0/16).

## 1. Images, cluster-wide

`ferry-registry` already served loaded images to machines, off by default. It
is now on by default and is the one place a loaded image is found from:

- **ferry-cri asks it first.** Before pulling from the real registry,
  `ImageMirror.swift` sends a HEAD for the manifest to `127.0.0.1:<port>`. On a
  200 it pulls from there (plain HTTP on loopback) and tags the image under its
  own name. Anything else goes upstream as before. The HEAD is there so a
  registry that is not running costs one refused loopback connection rather
  than Containerization's three retries a second apart.
- **It asks the other Macs.** A name it does not hold is looked up on each
  peer's registry, over a TLS port of its own (`5051` + shift). Both ends
  present their node's kubelet client certificate and verify the other's,
  which must chain to the cluster CA and be in group `system:nodes`. The
  manifest (and an index's child manifests) is fetched and recorded at once.
  Each layer is fetched the first time something asks for it, streamed to the
  client and into the store together, and its digest checked before it is
  kept. The peer port serves only the local store, so two Macs missing a name
  cannot ask each other in a circle. A peer that does not answer is skipped for
  30 seconds, so a sleeping Mac adds nothing to every other pull. Peers come from the peers
  file ferry-streamer already keeps.
- **`ferry image load` loads into this Mac's other nodes too**, so
  `imagePullPolicy: Never` works on every node here. Machines and other Macs
  need `IfNotPresent`, and the load says so.

Both ports are read-only. Anything but GET/HEAD is 405, and pods cannot reach
either port in a useful way.

### Measured

The test used a 69 MB image (busybox plus a 64 MiB random layer) loaded on the
Mac's node, and a public 43.5 MB image for comparison with a real registry.
"Pulled" is the kubelet's own figure, which includes unpacking to ext4.
"Fetch" is ferry-cri's log of the registry part.

| where the pod ran | image | pulled in | of which, fetch |
|---|---|--:|--:|
| added node `n1`, `Never` | loaded one | loaded at `ferry image load` | -- |
| added node `n2`, added after the load | loaded one | 186 ms | 134 ms |
| node `n3` behind a second "Mac" (empty store, only source the peer port) | loaded one | 295 ms | 202 ms |
| machine `worker-1`, through the Mac's registry | loaded one | 161 ms | -- |
| added node, from the real registry (public.ecr.aws) | python:3.12-slim | 2002 ms | -- |
| node behind the second "Mac", from the peer | python:3.12-slim | 497 ms | 123 ms |
| added node, from this Mac's registry | python:3.12-slim | 527 ms | -- |

The peer transfer was 67 MB in 173 ms through the TLS port. The second "Mac"
is a second `ferry-registry` on this Mac with an empty store and the first
one's peer port as its only peer, and a node pointed at it. That is the whole
path except the wire. Over a real LAN, add the transfer time. 43.5 MB is
~0.35 s at 1 Gbit/s. Two physical Macs were not available.

`ferry image load` of the 69 MB image into the Mac's node, one added node and
the registry: 0.99 s.

Who gets in, checked on the running cluster:

```
pod -> Mac's LAN address, registry port      403 Forbidden (source 10.172.1.3)
Mac, peer port, no certificate               TLS handshake refused (curl exit 56)
```

In `ferry-registry/peers_test.go`, a node certificate from the cluster is
answered, a cluster-signed certificate outside `system:nodes` is refused,
another cluster's node is refused, and a node's PUT is 405.

### What it costs

- One process, 15 MB resident. It used to run only with machines.
- A pull of anything not loaded anywhere pays one loopback HEAD, 0.55-0.87 ms
  measured, plus one round trip per live peer.
- No extra disk. The registry's blobs are hard links to the load's, so the
  registry does not store a loaded image a second time. Each node still unpacks its own
  ext4, which a pull always did.

## 2. A disk for a machine, after boot

Experiment 26 found that Virtualization.framework will attach a USB mass
storage device to a running VM. What was missing was everything around it.

- **Kernel.** Apple's configuration has neither USB nor SCSI. The nine
  symbols are now `kernel/usb-storage.config`, appended by every kernel build.
  It costs mode 1 nothing measurable, because the drivers only probe when
  there is a USB controller and only machines get one. Pod create-to-Ready on
  the Mac's node, six in a row, was 0.94-1.05 s steady on the old kernel and
  0.95-0.97 s on the new one. ferry turns the rest on only when the kernel
  carries usb-storage.
- **`ferry-storage`** offers `ferry-local-block`, not the default. A
  single-writer claim in it, scheduled onto a machine, is a sparse image in
  the volume's directory and a FlexVolume PV (`ferry.dev/block`) pinned to
  this Mac's machines. Any of them will do, so a pod can come back on a
  replacement. On the Mac's own node it is what `ferry-local` already gives a
  ReadWriteOnce claim, ferry-cri's disk. ReadWriteMany stays a directory.
- **`ferry-machined`** decides which machine holds each disk. That is the
  attach/detach controller's job, done from the Mac where the disk is. From
  pods, claims and volumes in an informer cache, it writes each machine's
  `.usb` file. Each disk goes to one machine and stays there while it is still
  wanted there. It reacts to pod and claim events rather than waiting for its
  2 s tick.
- **`ferry-node`** formats the image the first time (the same rules and writer
  as ferry-cri's), labels the filesystem with the claim, takes the flock on the
  volume directory that ferry-cri takes, so a claim cannot be on a machine and
  a pod VM at once, and attaches it. The kernel command line carries
  `usb-storage.delay_use=0`, because a virtual disk needs no spin-up second.
- **The node image's `ferry.dev/block` driver** finds the disk by label, mounts
  it once under `/var/lib/ferry-block`, and bind-mounts it into each pod on the
  node, so two pods on one machine share one mount. That is ReadWriteOnce as
  Kubernetes means it.

### Measured

```
init container (root):   chown 999:999 /block && chmod 700 /block   block-chown-ok
app (uid 999):           drwx------ 999 999 /block
                         -rw-r--r-- 999 999 /block/mine
second pod, same node:   sees the same files, 999:999, at the same time
pod on another machine:  waits ("waits for pvc-923c..., which is attached to worker-0")
first machine's pods go: the waiting pod is Ready 3.37 s later, /block/mine 999:999, "hi"
new machine, same claim: drwx------ 999 999, contents intact
```

From the logs, the framework's attach took 6-43 ms. The guest had the
filesystem mounted 50-130 ms after the USB device appeared, against about a
second in experiment 26 before `delay_use=0`.

Pod create-to-Ready on a machine with a fresh claim, three rounds each:

| class | attach on the 2 s tick | attach on the event |
|---|---|---|
| `ferry-local-block` | 4.55, 4.58, 3.87 s | 3.70, 1.89, 1.89 s |
| `ferry-local` | 2.01, 1.44, 1.88 s | 1.88, 1.90, 1.90 s |

So once reacting to events, a block claim costs a pod start nothing
measurable after the first. The first pays the format.

Throughput from a pod on a machine, three rounds: 2000 writes of 4 KiB with
`oflag=dsync` (each a commit), then 256 MiB with one fsync:

| | synced 4 KiB | per write | 256 MiB + fsync |
|---|--:|--:|--:|
| `ferry-local-block` (USB mass storage) | 6.4-9.6 MB/s | 0.43-0.64 ms | 0.54-0.99 GB/s |
| `ferry-local` (virtiofs share) | 26-32 MB/s | 0.13-0.16 ms | 1.1-1.4 GB/s |
| emptyDir (the machine's own virtio disk) | 44-47 MB/s | 0.09 ms | 1.5 GB/s |

That is the same fraction of virtio that experiment 26 measured, and the
reason this is a class to ask for rather than the default. It gives `chown`,
at about 2,000 commits a second instead of 7,000.

### Two things running it found

- **A pod deleted with `--force` had its disk pulled out while mounted.** It
  leaves the API at once, before its kubelet has unmounted anything, and
  detaching on the pod's disappearance alone gave three aborted journals in
  one guest. The driver now writes a lease beside the image, through the
  volumes share the Mac also sees, while the filesystem is mounted, and removes
  it after a clean unmount. ferry-machined does not detach a disk whose lease
  names its holder. Measured again with three pods force-deleted at once, the
  guest unmounted cleanly at 27.04 s, the detaches came 0.8 s later, and there
  were no I/O errors.
- **One machine stopped during the unprotected run.** Its VM was gone
  (`Invalid virtual machine state` on the next attach) with no console
  captured, since the console was not verbose. It did not recur in the runs
  after the lease, with `FERRY_NODE_VERBOSE=1`, including the same
  three-at-once force delete. Unexplained. The likeliest reading is a guest
  that did not survive disks removed under active mounts, which the lease now
  prevents, but that is a reading and not a measurement.

### A correction: virtiofs chown is not refused, it is not kept

GAPS.md says chown on a virtiofs volume fails with EPERM. On a machine, on
this macOS, it did not. `chown 999:999 /shared` as root **succeeded**, and a
uid-999 process then saw `/shared` as `999 999`. A second pod on the same
machine, running as root, saw the same directory, and a file the first had
made, as `0 0`. On the Mac both are `501 20`. So the share reports each
caller's own uid as the owner and keeps nothing. That is worse than EPERM in
one way, because a chart's init container believes it worked, and it is why
the block class is needed rather than a fix to the share. Mode 1 was not re-run.

## 3. NFS served by the Mac, unprivileged

`nfsspike/` is ~170 lines of willscott/go-nfs v0.0.4 over go-billy's osfs,
running as the user on a high port, with ownership kept in an xattr
(`dev.ferry.owner`) on the Mac's file and reported back in GETATTR. A new
entry takes its directory's owner. `NFS_DURABLE=1` fsyncs a file opened for
writing when go-nfs closes it.

Mounted with util-linux `mount -i -t nfs -o
vers=3,proto=tcp,nolock,port=27090,mountport=27090,mountproto=tcp,addr=...`,
from a privileged pod on a machine (server at the machine network's gateway)
and from a mode 1 pod (server at the Mac's LAN address). No rpcbind, no root
on the Mac.

```
chown 999:999 /nfs/data && chmod 700 /nfs/data               chown-ok
uid 999: echo mine > /nfs/data/f                               ok
drwx------ 999 999 /nfs/data    -rw-r--r-- 999 999 /nfs/data/f
on the Mac: dev.ferry.owner: 999:999
```

Throughput, same pod, same test as above:

| | synced 4 KiB | per write |
|---|--:|--:|
| NFS spike, no fsync | 13-23 MB/s | 0.18-0.31 ms |
| NFS spike, fsync on close | 19.5-25 MB/s | 0.16-0.21 ms |
| virtiofs share, same pod | 26-33 MB/s | 0.12-0.16 ms |

So it runs at roughly the share's speed, three times the USB disk's, and it
would close RWX chown and cross-Mac access together. The server is on the
Mac's LAN address, which pods in both modes on every Mac already reach.

It is not built as a StorageClass because of what the spike also showed:

- **No permission checks.** go-nfs parses the RPC's AUTH_UNIX credential and
  does not pass it to the filesystem, so the server cannot check access. A
  uid-999 process from the mode 1 pod wrote into a root-owned 0700 directory.
  For the same reason a new file takes its directory's owner instead of its
  creator's. Both need go-nfs forked to carry the credential to the handler.
- **`FILE_SYNC` without a sync.** Every WRITE is acknowledged as stable and
  nothing is flushed. `NFS_DURABLE` fixes that in the spike, at small cost.
- **No export scoping.** Anything that reaches the port mounts everything.
  It needs an allowlist of the pod network, the machine subnet and the peers,
  and a per-volume root, since go-nfs's mount handler ignores the path.
- **No mounter.** Mode 2's kubelet would need `mount.nfs` (nfs-common) in the
  node image for a PV's `nfs:` source. Mode 1 needs ferry-cri to mount it
  through vminitd, since the Mac's kubelet cannot.

With those, `ferry-nfs` is a small daemon and a provisioner branch. Without
them it would ship ownership that is reported and not enforced.


## Files

- `block-claim.yaml`, `perf.yaml`, `nfs-spike.yaml`: the pods measured above.
- `nfsspike/`: the NFS server spike, its own module.
- `run.sh images|volumes|nfs`: the same runs.
