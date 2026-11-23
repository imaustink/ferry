# An image that arrives after boot, mounted into the running VM

**Question.** A pod's images are disks attached when its VM boots, and
Virtualization.framework cannot add a disk to a running VM. So a container
whose image the VM was not booted with has cost the pod its VM:

- A native sidecar with a main container whose image was not pulled yet, which
  is every first run. The kubelet pulls the main image only after the sidecar
  starts, so the VM booted for the sidecar did not have it. The pod was
  recreated (`SandboxChanged`).
- An init container followed by such a main container: the VM was stopped and
  booted again.
- `kubectl debug` with an image the pod does not run: refused.

[Experiment 31](../31-restart-in-place/FINDINGS.md) left two reasons there was
no way round it. The pod VM has no USB controller, and the guest agent cannot
set up a loop device. Containerization 0.51 added root-of-VM processes (#1020):
a process created with no container, in PID 1's namespaces, which can be given
capabilities. Is that enough to loop-mount an image file that arrives after
boot, where containers are built?

**Answer.** Yes. ferry-cri now does it: a late image is mounted in 28-42 ms, and
the container joins the running pod.

## The probe

`late-disks` boots a LinuxPod on Containerization 0.57.0, with ferry's kernel
and guest agent, with one busybox container, one image disk and one empty
volume attached at boot, and an empty virtiofs share. After boot it puts disk
images into the share (clonefile, 0.2 ms), and runs busybox scripts as
root-of-VM processes with CAP_SYS_ADMIN. busybox:latest is dynamically linked,
and the VM root has no loader of its own, so it runs through the image's.

| | result |
|---|---|
| loop-mount a disk that reached the share after boot, read-only | `/dev/loop0` on `/run/volumes/late-img`, and **vminitd sees the mount**, which is where container roots are assembled |
| cold read of a 31 MB file, boot disk vs. late loop disk | 3.2-4.1 GB/s vs. 2.6-2.8 GB/s; host-cached, 10.8-12.4 vs. 3.5-4.2 GB/s |
| writable late volume: 4 KiB writes, each fsynced | 0.93 ms vs. 0.87 ms on a boot disk (process start dominates both) |
| 256 MiB sequential + fsync | 0.55-0.83 GB/s vs. 0.75-2.6 GB/s |
| does a synced write reach the Mac's file | **yes**: a copy of the image taken on the Mac while still mounted held the marker |
| `chown 1234:5678` on the late volume | works; it is ext4 in the guest kernel, not a virtiofs directory |
| detach | `umount` + `losetup -d` leave no loop devices |

Reads from a late disk are slower than from a virtio disk once the Mac has the
file cached, and no slower cold. Neither is something an image's start-up
notices.

Two traps, both in the probe rather than the mechanism. A file deleted on the
Mac stays cached in the guest under its old name, so a script redirecting to it
fails before printing anything: use a new file per step. And `ash` reads an
uptime of `029` as octal.

## In ferry-cri

`PodRootfsProvider.attachLate`, called from `createContainer` when a booted,
ready VM lacks only the container's image:

1. clone the image's disk into `<state>/late/<sandbox>/late-<n>.ext4`, along
   with `bin/ferry-loop`;
2. add that directory to the VM's virtiofs share (`hotplugVirtioFS`, which ferry
   already used for late share mounts); the guest sees it as
   `/run/virtiofs/<tag>`;
3. run `ferry-loop FILE /run/volumes/ferry_late_<n> ro` as a root-of-VM process
   with CAP_SYS_ADMIN;
4. record the mount, so the container's overlay uses it as its lower layer, and
   a later rebuild of the sandbox boots with the image attached.

If any step fails, ferry-cri does what it did before: rebuilds or recreates.

`guest/ferry-loop` is a static linux/arm64 Go binary (1.7 MB) that `ferry
build` cross-compiles. It attaches the file with `LOOP_CONFIGURE`, read-only and
autoclear, sets 1 MiB read-ahead as ferry-cri does for image disks, and
mounts it. The first version closed the device before mounting, so autoclear
detached it and the mount failed with EIO. `mount -o loop` holds the device
until the mount has its own reference, and so does ferry-loop now.

### Measured on a cluster

| | before | now |
|---|---|---|
| native sidecar + main image pulled after it started | `SandboxChanged`, pod recreated | image mounted in **40 ms**; sidecar and main 0 restarts |
| init container, then a main image pulled after it | VM stopped and rebooted | mounted in **38 ms**; main crash-looped in place, no `SandboxChanged` |
| `kubectl debug --image=<another image>` | refused | mounted in **28 ms**; debug container running, main untouched |
| three more debug containers, three new images, one pod | refused | 31-37 ms each, all running |

## Is a late volume as durable as a boot volume disk?

The bar is what a pod volume disk has today. ferry-cri attaches one with
Containerization's default, `VZDiskImageSynchronizationMode.fsync`: a guest
flush is a host `fsync()`, not `F_FULLFSYNC`. The cluster's `durability`
setting governs etcd and machine roots, not pod volume disks.

`DURABILITY_ONLY=1` runs `fsyncbench` (4 KiB `pwrite` + `fdatasync`, in one
process) in the guest, the same loop on the Mac, and `sample`s the VM process
while each guest loop runs:

| per 4 KiB write | µs | VM process stacks during it |
|---|---|---|
| guest, no sync (either disk) | 0.3 | idle |
| Mac, `fsync()` | 21 | |
| guest, boot volume disk, `fdatasync` | 82 | no I/O calls on any stack |
| guest, late loop volume, `fdatasync` | 166 | `fsync` 854 samples, `fcntl` 0 |
| guest, file on the virtiofs share, `fdatasync` | 127 | `fsync` 1012 samples |
| Mac, `F_FULLFSYNC` | 4,630 | |

A late volume's flush goes guest ext4 → loop → virtiofs `FUSE_FSYNC`, and
the VM process turns it into a host `fsync()`. That is what `.fsync`
documents for a block device. Neither kind of disk pays for an `F_FULLFSYNC`
per flush. VZ serves the block device without a thread sitting in a system
call, so the sample says nothing about it. A late volume's synced write costs
twice a boot disk's, 166 µs against 82.

`CRASH_ONLY=1` checks that nothing synced is left in a guest cache. The guest
writes a counter to a raw late loop device, syncs it, then writes it to an
acknowledgement file on the share. The Mac waits for a given acknowledgement,
`SIGKILL`s the VM process, and reads the disk file:

| killed after ack | last ack on the Mac | counter in the disk file |
|---|---|---|
| 528 | 584 | 585 |
| 1003 | 1089 | 1089 |
| 2002 | 2090 | 2090 |
| 3013 | 3109 | 3109 |
| 5026 | 5117 | 5118 |

Every acknowledged write was on the Mac. One ahead is a write that was synced
but not yet acknowledged.

## Late block volumes in ferry-cri

A late volume goes through Containerization's `LinuxPod.attachVolume` (#1022),
called by `PodRootfsProvider.attachVolume` when a booted VM lacks volumes the
container mounts. LinuxPod mounts it where a boot volume goes,
`/run/volumes/<name>`, so the container's shared mounts and subPaths are the
same, and unmounts it in `stop()` after the containers. That unmount is what
writes back what was never synced (see the control below). For a disk-image
volume, attachVolume asks the VM's hotplug provider for a device, and ferry's:

1. hard-links the volume's own image (a claim's `disk.ext4`, an emptyDir's
   `.ferry-disk.ext4`) into `<state>/late/<sandbox>/rw/`. A clone would not see
   the guest's writes, and sharing the volume's real directory would show the
   pod every other volume beside it;
2. shares `rw/` read-write;
3. runs `ferry-loop attach FILE rw N` from the read-only late share, which puts
   the file under `/dev/loopN`. ferry-cri picks N (512 plus a reserved
   index), so it knows the device without reading the helper's output, and
   hands it back for LinuxPod to mount.

ferry-cri then creates the subPaths the container names, with the volume
root's mode. A `medium: Memory` emptyDir is attachVolume's own tmpfs, carried
across a later rebuild like any memory volume.

The first version did LinuxPod's part itself: its own mount, and before each
of three stop paths, stopping the pod's containers, a guest `sync`, and an
unmount of each late volume. attachVolume made all of that unnecessary. The
measurements below were taken on both versions.

| | before | now |
|---|---|---|
| native sidecar, then main mounting a RWO claim | `SandboxChanged`, pod recreated | mounted in **24 ms**, 0 restarts; `chown` kept |
| init container, then main mounting an emptyDir whole and by subPath, as uid 1000 | VM stopped and rebooted | mounted in **49 ms**; one loop device, subPath writable |
| main writes 4-8 MiB without syncing, pod deleted within ~1 s, new pod reads the claim (×4) | n/a | every file intact, md5 matches, no journal recovery |
| the same, then `ferry restart` rather than a delete | n/a | intact, no journal recovery |
| init container, then main with a 64 MiB `medium: Memory` emptyDir as uid 1000 | VM rebooted | tmpfs mounted in **2 ms**, `size=65536k`, 1777, writable |

What the flush saves (`CONTROL_ONLY=1`): 4 MiB written to a late ext4 volume
without syncing, the VM stopped ~650 ms later, and a second VM booted with
the volume attached as a disk, as the next pod would be:

| | runs | the next VM reads |
|---|---|---|
| stopped as LinuxPod.stop does | 5 | journal recovered, **the file does not exist** |
| guest `sync` and unmount first, as LinuxPod.stop unmounts an attached volume | 4 | the file, md5 matching, no recovery |

## What this leaves

- **A late volume's synced writes cost twice a boot disk's** (166 µs against
  82) until something else rebuilds the VM and attaches it as a disk. That is
  the price of the virtiofs round trip. Nothing else that arrives after boot
  costs the VM any more.
- **ferry-loop's errors are an exit code.** A root-of-VM process run without
  stdio has nowhere to write. ferry-cri logs `ferry-loop exited N` and falls
  back.
- Every node gets it: the main node, a joined Mac, and a `ferry node add` node
  (a sidecar pod on one mounted its main image in 34 ms).

## Reproducing

```
swift build -c release
codesign --force --sign - --entitlements entitlements.plist .build/release/late-disks
.build/release/late-disks list
WORK=/tmp .build/release/late-disks run docker.io/library/busybox:latest <a large image>
FERRY_LOOP=../../bin/ferry-loop HELPER_ONLY=1 WORK=/tmp .build/release/late-disks run ...
(cd fsyncbench && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o fsyncbench .)
DURABILITY_ONLY=1 FSYNCBENCH=$PWD/fsyncbench/fsyncbench WORK=/tmp .build/release/late-disks run ...
CRASH_ONLY=1 CRASH_AFTER=2000 FSYNCBENCH=$PWD/fsyncbench/fsyncbench WORK=/tmp .build/release/late-disks run ...
CONTROL_ONLY=1 CONTROL_FLUSH=0 WORK=/tmp .build/release/late-disks run ...   # 1: flush first
```

The durability runs `sample` and `SIGKILL` the newest
`com.apple.Virtualization.VirtualMachine` process, which is the probe's own
VM only if nothing else booted one after it.

It reads ferry-cri's state directory (`FERRY_CRI_STATE`, default
`/tmp/ferry-run/cri`) for image disks and the unpacked guest agent, so start a
cluster from this branch once first.
