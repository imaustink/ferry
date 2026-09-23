# Experiment 31: a container restarts inside its running pod

**Question.** GAPS.md said a container that crashes in a multi-container pod restarts the whole pod. It gave two reasons:

- Virtualization.framework cannot add a device to a running VM;
- Containerization will not start a stopped container again.

Is either reason the real blocker?

**The second one never was.** The kubelet does not restart a container. It creates a new one, with a new ID and `attempt + 1`, so LinuxPod's refusal to restart a stopped container was never reached.

The real blocker was that **each container was a device**: a per-container clone of its image's ext4, attached when the VM booted. Two things followed:

- a new attempt needed a new disk, which a running VM cannot take;
- Virtualization.framework had no hotplug provider for Containerization to call.

**The change** (`ferry-cri/Sources/ferry-cri/PodRootfs.swift`):

- Each distinct image the pod spec names is attached once, read-only, when the VM boots.
- Each pod gets one sparse 16 GiB scratch disk. It is a `clonefile` of a template with 64 ready-made upper/work slots and no journal.
- A container's root is an overlay of the image and its slot.
- `PodRootfsProvider` is the hotplug provider that was missing. It touches no hypervisor: a new container is a new overlay on disks the VM already has.
- New virtiofs directories are added to the running VM's `VZMultipleDirectoryShare`. This works on a live VM: a container that joined after boot wrote a termination message that reached the pod's status.
- A dead container's upper directory is removed by a short `rm` container, so the scratch disk does not grow with every crash.

All containers go through `addContainer` after `create()`, boot-time ones included. `replaceBootedPod` is the fallback for a container whose image or block volume the running VM does not have:

- if nothing is running, the VM is rebuilt;
- if something is running, the sandbox is recreated;
- an ephemeral container is refused.

**Measured.** "Before" is d321955 plus tracing only.

| | before | after |
|---|---|---|
| one container of two crashes | the pod never ran again: the sibling restarted 7–9 times, the IP moved, then `ENOTSUP` forever | the sibling keeps PID 1 and an uptime equal to the pod's age, the IP is unchanged, only the crasher's restartCount moves |
| single-container crash to running again | ~1.8 s (VM rebuilt) | **~45 ms** (create 10–17 ms + start 26–41 ms) |
| page cache, 4 × `python:3.12-slim` each reading `/usr` | 673 MiB | 259 MiB |
| init containers + a native sidecar | never Ready | Ready in ~6 s |

StartContainer at boot, by container count (median):

| containers | before | after |
|---|--:|--:|
| 1 | 274 ms | 305 ms (+30 ms) |
| 8 | 495 ms | 459 ms |
| 20 | 850 ms | 675 ms |
| 24 / 40 / 70 | fails, "no free indices" | Ready in 1.9 / 2.0 / 3.0 s |

For a single-container pod the +30 ms is one more device, one more ext4 mount and a separate agent session. For pods with more containers it is a saving, and the ceiling of about 22 containers per pod is gone.

Scratch growth, for a container writing 64 MiB per crash:

- without the cleanup, 199 → 391 MiB over 4 restarts;
- with it, 199 → 239 MiB, flat.

**Fixed on the way:**

- ExecSync is implemented; exec probes never ran before.
- `stopContainer` sends SIGTERM, then SIGKILL once the grace period is up. Before, it sent SIGKILL at once.
- ContainerStatus reports mounts; the kubelet never got termination messages before.
- Attach ends when its container exits; `kubectl debug -i` and `kubectl run -i` used to hang.
- `readOnlyRootFilesystem` is honoured.
- A double-boot race is fixed (`awaitBoot`).

**Checked:** an emptyDir, the ServiceAccount token, DNS and the GPU socket all survive a restart. `kubectl debug` with an image the pod already runs joins in place, and `-i` exits cleanly. With another image it is refused with a clear message, and the pod is not touched.

**On the merged branch.** In a two-container pod whose second container exits every 6 s, after two crasher restarts:

- the web container had 0 restarts, and its uptime ran on from 8 s to 28 s;
- a file in a `medium: Memory` emptyDir was still there;
- `kubectl logs --previous` answered 15 of 15.

**Remains:**

- A container whose image was not attached at boot cannot join a running pod. The pod kernel is given no USB controller, and the agent cannot set up a loop device.
- A block volume that arrives after boot causes one VM rebuild.
- `kubectl debug --target` does not join the target's PID namespace.
- Multi-node, and a PVC combined with a hot-added container, were not tested.
