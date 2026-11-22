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

## What this leaves

- **A block volume that arrives after boot still costs a VM rebuild.** The
  probe says the same route would work, with a writable mount, working
  `chown`, and synced writes reaching the Mac's file. What is not yet
  measured is whether `F_FULLFSYNC` reaches the SSD through virtiofs, which is
  what ferry's `power-loss` durability promises for volumes. Until it is,
  volumes stay on boot disks.
- **ferry-loop's errors are an exit code.** A root-of-VM process run without
  stdio has nowhere to write. ferry-cri logs `ferry-loop exited N` and falls
  back.
- **`ferry node add` nodes keep the old behaviour.** Only the main node and a
  joined Mac pass `--loop-helper` today.

## Reproducing

```
swift build -c release
codesign --force --sign - --entitlements entitlements.plist .build/release/late-disks
.build/release/late-disks list
WORK=/tmp .build/release/late-disks run docker.io/library/busybox:latest <a large image>
FERRY_LOOP=../../bin/ferry-loop HELPER_ONLY=1 WORK=/tmp .build/release/late-disks run ...
```

It reads ferry-cri's state directory (`FERRY_CRI_STATE`, default
`/tmp/ferry-run/cri`) for image disks and the unpacked guest agent, so start a
cluster from this branch once first.
