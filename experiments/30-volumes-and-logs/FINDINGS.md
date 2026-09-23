# Experiment 30 — Memory emptyDirs, late subPaths and `kubectl logs --previous`

**Question.** GAPS.md listed three things about volumes and logs as known and
deliberate. Each came from a real constraint, and the question was whether that
constraint was really the one in the way:

1. **`medium: Memory` is disk.** macOS has no tmpfs, so ferry's kubelet makes a
   memory emptyDir a plain directory, and ferry-cri turned it into an ext4 image
   on the Mac like any other emptyDir. The pod VM does have tmpfs, and
   Containerization has `PodVolume.Source.tmpfs`.
2. **A subPath added after a volume's first format is `0755 root`**, because
   vminitd's mkdir ignores the mode it is asked for.
3. **`kubectl logs --previous` fails for a while after each crash**, because the
   kubelet removes the second-newest dead container while the pod's status
   still names it.

**Method.** A private cluster from this worktree (`./ferry up`, Kubernetes
v1.34.0), A/B against the `main` build of `ferry-cri` with everything else the
same, including the kubelet. The scripts here are the whole experiment:

| script | what it does |
|---|---|
| `starttime.sh N` | `kubectl apply` to Ready, N pods one at a time: plain / disk emptyDir / memory emptyDir |
| `previous.sh S` | a container that crashes every 2 s; `kubectl logs --previous` every 0.2 s for S seconds after its first restart |
| `latesubpath.sh` | a claim formatted by one pod, then a non-root pod mounting a subPath the first never named |
| `memory.yaml` | an init container seeds a memory emptyDir; the non-root main container reads it through the volume and a nested subPath |
| `memcrash.yaml` | a memory emptyDir with a 32 MiB file, across container crashes |
| `memlimit.yaml` | a memory emptyDir with no sizeLimit in a pod with `limits.memory: 256Mi` |
| `writebench.sh` | the same writes to a disk and a memory emptyDir in one pod |

Apple M4 Max, 16 cores, 128 GiB, macOS 26.6.2. Default pod VM 2 CPUs, 512 MiB.

**One thing found on the way.** The kubelet binary the main checkout had built
predated the fix to `SafeMakeDir` in `patches/kubelet/.../subpath_darwin.go`: it
resolved the subPath against its working directory, so *any* subPath that did
not exist yet failed with `subpath "late/sub" escapes volume`. Rebuilding the
kubelet from the tree fixed it. Every number below is from the rebuilt kubelet,
on both sides of the A/B.

## 1. Memory emptyDir

ferry-streamer already has the pod spec open for ferry-cri; it now also reports
`memoryVolumes`, each memory emptyDir's name and sizeLimit. Those become a tmpfs
pod volume, mounted at `/run/volumes/<name>` where the image would have been and
bound into containers the same way, subPaths included.

What the pod sees, `memory.yaml`:

```
uid=1000 gid=1000 groups=1000
tmpfs /sub tmpfs rw,relatime,size=65536k 0 0
tmpfs /mem tmpfs rw,relatime,size=65536k 0 0
drwxr-xr-x    2 1000     1000   60 owned        <- chowned by the init container
drwxrwxrwx    2 root     root   40 late/sub     <- the subPath, root's mode
from-init                                       <- written in the init container's VM
sub-writable
owned-writable
```

`sizeLimit: 64Mi` is enforced by the tmpfs itself: a 48 MiB write, then another,
stops at 16 MiB with the filesystem at 100%. On Linux the kubelet evicts a pod
over its sizeLimit; here the host directory it measures is empty, so the limit
is ENOSPC instead of eviction.

**Size.** As the kubelet sizes one on Linux: the sizeLimit, capped at the pod's
memory limit, or the pod's limit when there is no sizeLimit. With neither, the
guest kernel's default, half the VM. `memlimit.yaml`: `limits.memory: 256Mi`, no
sizeLimit, gives a 256 MiB tmpfs, and 128 MiB written into it shows up in the
container's own cgroup, `135 MiB of 256` -- the same accounting as Linux.

**The VM is grown by the tmpfs size**, on top of the limit and headroom. While
one VM lasts that is more than needed, since the pages are charged to the
container. But the contents carried into a replacement VM (below) are written
by the guest agent, which no container limit covers, and the container can then
use its whole limit besides. Guest memory is lazily backed, so the extra costs
nothing until written. `memlimit` got a 768 MiB machine (`free` says 723).

**Surviving VM rebuilds.** An emptyDir outlives its containers. Here a container
restart and an init container handing over to the next are each a new VM, and a
tmpfs in the old one dies with it. So before the old VM stops, ferry-cri
archives the tmpfs out of it through the agent's copy RPC, holds the archive in
its own memory (never on the Mac's disk), and extracts it into the new VM after
it boots, before any container starts. `memcrash.yaml`, three crashes:

```
attempt 0 big=2b3e6ad2 mode=1777
attempt 2 big=2b3e6ad2 mode=777
attempt 3 big=2b3e6ad2 mode=777
```

| carried | archive | archive out | restore in |
|---|---|---|---|
| a 10-byte file and a directory | 315 B | 7.6 ms | 2.6 ms |
| 32 MiB of `/dev/urandom` | 33.6 MB | 488 ms | 49 ms |

The out direction is the guest gzipping (vminitd always compresses), about
65 MB/s on incompressible data. It is paid on the restart path only, which the
kubelet's crash backoff already spaces at 10 s or more; a pod with no memory
emptyDir pays nothing.

**Writes,** `writebench.sh`, three runs, ms at 10 ms resolution:

| | disk emptyDir (ext4 image) | memory emptyDir (tmpfs) |
|---|---|---|
| 256 MiB `dd conv=fsync` | 190 / 150 / 100 | 30 / 40 / 50 |
| 2000 small files + syncfs | 40 / 40 / 40 | 10 / 10 / 0 |
| 500 × 4 KiB append + fsync | 210 / 430 / 370 | 70 / 80 / 70 |

The last row is mostly 500 forks of `dd`; the difference, about 0.6 ms per
fsync, is the disk.

## 2. Late subPath

vminitd's mkdir calls `FileManager.createDirectory` with no attributes, under a
022 umask. Its copy RPC is better: a directory entry in the tar it extracts is
made and then `fchmod`ed to the entry's mode, which is exactly what the kubelet
does on Linux (`mkdirat`, then `fchmod` to the volume root's mode, because
`mkdirat` was subject to the umask). So a missing subPath is now a stat, and a
one-entry tar with the root's mode only if it is missing. Both are resolved by
the agent inside the volume with symlinks confined to it. Building our own
vminit was the alternative; it needs the Swift Static Linux SDK and an init
image to host, for a result this gets from the stock agent.

`latesubpath.sh`: the first pod formats the claim and makes `kept` 0700; the
second, uid 1000, mounts `new/dir`:

| | main | this |
|---|---|---|
| `new` (parent) | `drwxr-xr-x root` | `drwxr-xr-x root` |
| `new/dir` | `drwxr-xr-x root` | **`drwxrwxrwx root`** |
| write to the subPath | `Permission denied` | **written** |
| `kept`, made by the workload | `700 root` | `700 root`, left alone |

Parents are 0755 as the kubelet leaves them on Linux, where only the last
component is chmodded. The same path makes memory emptyDir subPaths.

## 3. `kubectl logs --previous`

The kubelet reads a container's log through `ContainerStatus.logPath`
(`kuberuntime_container.go` `GetContainerLogs`), and before removing a container
it globs `logPath*` and deletes those files (`container_log_manager.go` `Clean`).
So a link somewhere else survives the kubelet's cleanup, and a status that
points at it answers.

As a container exits, its log is hard-linked to `<state>/logs/<id>.log`: one
`link(2)`, no copy, no space until the kubelet deletes the original. When the
kubelet removes an exited container, its record moves to a map that
ContainerStatus still answers from, with `logPath` at the link, for 60 s, and
that ListContainers never shows, so nothing the kubelet derives from the listing
changes. Expiry unlinks.

`previous.sh 240`, a container crashing every 2 s, five restarts in the window:

| | polls | failed | failure windows after each crash |
|---|---|---|---|
| main | 921 | **255** (28%) | 32 s, 14 s, 16 s, 12 s |
| this | 932 | **0** | none |

The failures were all `unable to retrieve container logs for ferry://<id>`. The
window was 12-32 s, not the few seconds GAPS.md said; under CrashLoopBackOff the
kubelet's status update lags the removal by a sync period and more.

**Container IDs** used to restart from zero with ferry-cri, while the kubelet
remembers the IDs it saw -- a pod's status names its last container through a
runtime restart. IDs now start from the boot time shifted past a 24-bit
counter. The root filesystem clones a restart orphans, which reused IDs used to
overwrite, are removed at start along with the retained logs.

## Start time

`starttime.sh 10`, mean of ten, apply to Ready:

| | main | this |
|---|---|---|
| plain pod | 0.92 s | 0.91 s |
| disk emptyDir | 0.91 s | 0.91 s |
| memory emptyDir | 0.91 s | 0.91 s |

Every sample sits between 0.84 and 0.93 s, the kubelet's own cadence, so any
difference in ferry-cri is below what this can see. What changed on that path:
a memory emptyDir no longer creates and formats an image (a 16 MiB journal
write); a pod with subPaths makes one stat per subPath where it made one mkdir,
plus one stat of the volume root; a container exit adds one `link(2)`. A pod
with none of these runs the code it ran before.

## What is left

- **A carried tmpfs loses its sticky bit.** vminitd's extractor masks every
  mode with 0777, so the root comes back 0777 rather than 1777 after the first
  rebuild, and so does any sticky directory inside it. Fixing it means
  re-encoding the archive on the host without the root entry, or an agent that
  keeps the bit.
- **A VM that dies on its own takes its tmpfs with it,** as a node that loses
  power does on Linux. Only a rebuild ferry-cri does itself carries it.
- **A sandbox the kubelet recreates starts with an empty tmpfs.** On Linux an
  emptyDir outlives a sandbox; here the carry happens only within one.
- **sizeLimit on a memory emptyDir is ENOSPC, not eviction.**
- **If the pod spec could not be read at RunPodSandbox**, a memory emptyDir is an
  ext4 image as before: correct, and on disk.
