# A repeatable battery against kind and minikube

[Experiment 21](../21-density-vs-kind-minikube/FINDINGS.md) answered this
question once, by hand. This is the same comparison made repeatable. It has one
interface per stack, one battery that runs against any of them, and separate
instruments for the numbers the battery cannot measure accurately.

**The methodology, and every way this goes wrong, is
[docs/BENCHMARKING.md](../../docs/BENCHMARKING.md). Read that first.** What
follows is the result of the third run.

## Results, 19–20 September 2026

Apple M1 Max, 10 cores, 32 GiB, macOS 26.6. ferry at `317b1c5`, kind v0.33.0,
minikube v1.33.1, Docker Desktop 4.48.0. Image `alpine:3.20`, pre-pulled.

Ferry's two modes and kind all ran **v1.37.0**, the first run where ferry and
kind were on the same minor. minikube's own default is still **v1.30.0**, so that
column is not version-matched.

> **The mode 2 latency rows below are wrong.** The battery scheduled half of
> their pods onto the Mac node as mode-1 VMs. Corrected numbers are in
> [Correction](#correction-the-latency-rows-above-were-measuring-two-architectures-at-once).
> Lifecycle and memory rows are unaffected except as noted there.

| | mode 1 | mode 2 | kind | minikube |
|:--|--:|--:|--:|--:|
| create, cached | **14.43s** | 34.73s | 26.27s | 29.83s |
| delete | 4.67s | 10.53s | **0.50s** | 2.48s |
| pod start, median (n=5) | 0.83s | 0.82s | **0.62s** | 0.95s |
| 10 pods, all Running | 2.39s | 3.63s | **0.83s** | 2.38s |
| 20 pods, all Running | 4.67s | 2.72s | **1.07s** | 3.69s |
| idle memory | 398 MiB | **406 MiB** | 712 MiB | 492 MiB |
| memory per pod, at 20 | 219.7 MiB | **8.1 MiB** | 13.1 MiB | 16.2 MiB |
| needs Docker Desktop | no | no | yes (+286 MiB) | yes (+283 MiB) |

Memory is read **inside the guest that holds the pods**, the same instrument for
all three shared-kernel stacks. Mode 1 is the exception and has to be. Its pods
are separate VMs with no shared guest, so its figures are summed
`phys_footprint`. See BENCHMARKING.md. Mixing those two bases is the biggest
error available here, and it inverted this table's memory rows on the previous
run.

The Docker-side CPU column was withdrawn. Docker Desktop was hosting three
unrelated containers, its VM sat at 73–80% with every cluster *down*, and kind's
"cluster up" reading came in below its own baseline. Ferry's own figures, 0.30%
for mode 1 and 6.40% for mode 2, stand, because its processes are individually
identifiable.

## What this says

**Against minikube, ferry wins every row but one.** Mode 1 creates a cluster in
half the time, both modes start pods faster, and mode 2 finishes a twenty-pod
burst in 2.72s against 3.69s and costs half as much per pod. minikube's only win
is teardown. Discount for the version gap. The margins survive it.

**Against kind it splits.** Ferry wins the entry cost, 14.4s against 26.3s, the
largest margin in the battery. It also wins memory on a common basis, where
mode 2's 406 + 8.1n never crosses kind's 712 + 13.1n. Kind wins every latency
number involving a pod: 0.62s against 0.82s for one, 1.07s against 2.72s for
twenty.

**That last sentence does not survive the correction below.** Pinned and
watched, the single pod is a tie and ferry's *first* pod of a burst is faster.
What kind wins is concurrency, at 11.3ms per additional pod against ferry's
35.0ms.

## What moved between runs

| | run 1 | run 2 | run 3 |
|:--|--:|--:|--:|
| mode 2, pod start median | 0.92s | 0.92s | **0.82s** |
| mode 2, 20 pods | — | 4.78s | **2.72s** |
| mode 2, create cached | 41.23s | 32.03s | 34.73s |

Three fixes account for most of it, and all three are structural rather than
Kubernetes-level:

1. **A virtio entropy device.** `crng init done` went from 10.036679s to
   0.074620s, and node registration from 12,493 ms to 8,219 ms.
2. **`synchronizationMode: .fsync`** on the node's disk, so a guest fsync stops
   being a full host barrier. Twenty pods went from ~5.2s to ~2.2s.
3. **Kubernetes 1.36+**, for `OnPodSandboxReady`. Mode 2's single-pod time went
   from 0.83–1.95s to 0.82s five times out of five. The full-second tail that
   hit roughly one start in six is gone.

## Caveats on this run specifically

- **Mode 2's ten-pod time (3.63s) is slower than its twenty-pod time (2.72s).**
  It should not be. A separate four-round alternating A/B showed mode 2
  improving monotonically (1.83, 1.63, 1.59, 1.54s) where kind did not, so there
  is a warm-up effect neither instrument isolates. Ten pods runs first. It is
  reported as measured rather than dropped. Do not read it as a per-pod cost.
- **The host was under memory pressure**, with 9.0 GiB compressed and 1.3 GiB
  swap in use before the battery started.
- **Latency is n=5**, memory a single measurement at rest. Only the twenty-pod
  burst has repetition behind it, via `altbench.sh`. No confidence intervals are
  claimed.

## Correction: the latency rows above were measuring two architectures at once

**Every ferry2 latency figure in the table above is wrong**, and the cause is
in this harness rather than in ferry.

`run.sh` interpolates `${NODE_SELECTOR}` into its Deployment and `stacks.sh`
never set it for `ferry2`. With mode 2 enabled the cluster has two nodes of
different architectures, so the pods were scheduled across both.
`whereland.sh` measured an even 5/5 split of ten replicas with the battery's own
manifest. Half of every "mode 2" burst was mode 1, booting a VM per pod.

Re-measured with the pods pinned and the API watched rather than polled
(`timeline.py`, `burst.py`), on an all-v1.37.0 cluster:

| single pod, apply → Running | mode 2 | kind |
|:--|--:|--:|
| from a bare Pod | 534ms | 568ms |
| from a Deployment | 541ms | 544ms |

A tie, where the battery reported 0.82s against 0.62s.

The 20-pod burst is where the two still differ, and not in the way the battery
suggested:

| 20-pod burst | mode 2 | kind |
|:--|--:|--:|
| all created by | 142ms | 117ms |
| all scheduled by | 152ms | 122ms |
| **first** pod Running | **705ms** | 745ms |
| last pod Running | 1370ms | **959ms** |
| scheduled → first Running | **553ms** | 623ms |
| marginal cost per extra pod | 35.0ms | **11.3ms** |

**Ferry's single-pod path is faster than kind's. Its concurrency is 3.1×
worse**, and that is the whole of the remaining gap. The kubelet's own
`podStartSLOduration` shows the same shape from inside the node. Ferry's
fastest pod beats kind's (898ms against 970ms) and its slowest is far behind
(1559ms against 1233ms).

The ten-pod cell that the run above flags as an anomaly, 3.63s against a
twenty-pod 2.72s, is this bug, not a warm-up effect. The mixture differed
between the two cells.

The memory rows are probably affected too. Ten mode-1 pod VMs at ~220 MiB is
2,200 MiB against the 2,814 MiB observed at twenty pods, where a pinned mode-2
burst costs ~8 MiB a pod. That fits the mixture better than the guest-page-cache
explanation given in BENCHMARKING.md, but no dedicated run has confirmed it.

### What the gap is not

Each of these was measured, not reasoned about:

| | |
|:--|:--|
| the control plane or scheduler | all 20 pods scheduled by 152ms |
| API round trips across the host/guest boundary | 1.15ms from inside ferry's node vs kind's 0.84ms (`rtt.sh`) |
| the durability barrier | fsync 0.085ms vs kind's 0.098ms (`fsynccost.sh`) |
| CNI | `hostNetwork`, which skips it entirely, moves the last pod 3ms per pod |
| containerd | 20 containers in 165ms, 6× speedup from concurrency, no kubelet (`ctrconc.sh`) |
| kubelet configuration | neither sets kubeAPIQPS/Burst; ferry uses cgroupfs, kind the slower systemd (`knobs.sh`) |
| the harness's poll loop | costs 40.7ms against ferry, 48.5ms against kind (`pollcost.sh`) |

What remains is the CRI path as the kubelet drives it under concurrency, through
sandbox, CNI, container and status, which `ctr run` does not exercise. That is
where to look next.

## Where the concurrency gap is, and where it is not

The correction above leaves one real difference. Ferry's first pod of a burst
beats kind's and its last loses badly. This is three alternating rounds of 20
pods, with teardown between and free memory logged (`ab.sh`). It was written
after two runs minutes apart disagreed by 187ms on a figure that had strictly
*less* work to do:

| 20-pod burst, 3 alternating rounds | ferry | kind |
|:--|--:|--:|
| first pod (median) | **742ms** | 786ms |
| last pod (median) | 1400ms | **975ms** |
| marginal cost per additional pod | 34.6ms | **9.9ms** |

Ferry's first pod wins all three rounds; its last loses all three.

### The runtime is not the problem, and is the faster of the two

`crictl`, same version and same request on both nodes, with `network: NODE` so
CNI is out of it (`criconc.sh`):

| RunPodSandbox ×12 | ferry | kind |
|:--|--:|--:|
| issued serially | **38.2ms** each | 55.2ms each |
| issued at once | **6.5ms** each | 16.6ms each |
| speedup from concurrency | **5.87×** | 3.33× |

**Ferry's CRI is ~1.4× faster serially, ~2.6× faster concurrently, and
parallelises better.** Tuning containerd is the wrong target.

The first attempt at this measured 0 of 12 sandboxes on kind and reported
timings anyway. kind uses the systemd cgroup driver, and runc rejects a
`cgroup_parent` that is not a slice. The script now counts what it created and
says so. It is the same class of error as the `ctr` namespace mistake.

### Nor is the kubelet starved of work

- It learns about all 20 pods within **102ms** (`syncbatch.sh`), so watch
  delivery across the host/guest boundary is not pacing it.
- The control plane has all 20 scheduled by 152ms.
- Plain `ctr` creates 20 containers in 165ms with a 6× concurrency speedup
  (`ctrconc.sh`).

### It is the kubelet, feeding the runtime in waves

From containerd's own log, when each `RunPodSandbox` *arrived* (`criseq.sh`):

| | ferry | kind |
|:--|--:|--:|
| all 20 requests issued within | 427ms | **64ms** |
| largest gap between requests | 297ms | 7.5ms |

Kind's kubelet fires all twenty almost at once. Ferry's spreads them over
427ms, and containerd is not idle during the gaps. `stall.py` shows it busy
with `CreateContainer`/`StartContainer` for *earlier* pods. Ferry's kubelet
works a wave of pods through to completion before starting the next.

### Half of the excess is the projected serviceaccount volume

`syncPod` will not create a sandbox until `WaitForAttachAndMount` returns, and
every pod gets a projected serviceaccount token unless told otherwise. With
`automountServiceAccountToken: false` (`NOSA=1 burst.py`):

| 20-pod burst | ferry | ferry, no SA | kind | kind, no SA |
|:--|--:|--:|--:|--:|
| last pod | 1370ms | 1246ms | 959ms | 719ms |
| spread (first → last) | 665ms | **354ms** | 214ms | 150ms |
| marginal per pod | 35.0ms | **18.6ms** | 11.3ms | 7.9ms |

Removing it halves ferry's staircase. Both stacks improve, so this is not
ferry-specific, but ferry has roughly twice as much of it to lose, and is
still 2.4× behind afterwards. The volume manager's reconciler runs on a 100ms
loop, and 427ms is about four of those.

These two rows were taken minutes apart rather than alternating, and ferry's
"first pod" moved the wrong way between them (705ms → 892ms with *less* work).
Treat the direction as real and the magnitudes as provisional.

### What to look at next

Not containerd, and not the control plane. The remaining question is why
ferry's kubelet completes a wave before starting the next when kind's does
not, given the same binary, the same default configuration (`knobs.sh`
confirms neither sets `kubeAPIQPS`/`kubeAPIBurst`, and ferry uses the *faster*
cgroupfs driver where kind uses systemd), and a faster runtime underneath.
Raising the kubelet past `--v=2` would show the per-pod phase boundaries
directly. That currently needs a node-image rebuild, and is worth making a
runtime flag.

## The scripts

The battery:

| | |
|:--|:--|
| `lib.sh` | measurement helpers: footprints, guest memory, cumulative CPU |
| `stacks.sh` | one up/down/kubeconfig interface per stack, and which host processes belong to each |
| `run.sh` | the battery, run once per stack |
| `summarize.py` | `results/raw.tsv` → the comparison tables |

What the battery cannot measure accurately, measured separately:

| | |
|:--|:--|
| `m2mem.sh` | mode 2's memory read inside the guest, on kind's basis |
| `altbench.sh` | 20-pod burst, mode 2 vs kind, alternating with teardown between |

Diagnostics, each answering one question:

| | |
|:--|:--|
| `phases.py` | per pod: admit → volumes → sandbox → Running, from the kubelet's own log |
| `burstshape.py` | the spread *inside* a burst, since wall time is the last pod, not the typical one |
| `spread.sh` | do 20 pods start together, or in a staircase |
| `objrate.sh` | separates "the control plane created 20 objects" from "the node started them" |
| `m2-breakdown.sh` | where mode 2's idle memory goes |
| `m2-phases.sh` | where mode 2's bring-up time goes |
| `pleg.sh` | pod start with and without `EventedPLEG` (it is worse, see BENCHMARKING.md) |

Added while chasing the gap above:

| | |
|:--|:--|
| `timeline.py` | apply → object → scheduled → Running, watched, one clock |
| `burst.py` | the same split for N pods, with the node histogram and a `HOSTNET=1` mode |
| `whereland.sh` | where the battery's unpinned pods actually land |
| `pollcost.sh` | what one iteration of the battery's poll loop costs, per stack |
| `rtt.sh` | API round-trip latency from inside the node |
| `fsynccost.sh` | what a durability barrier costs inside the node |
| `ctrconc.sh` | containerd's own concurrency, serial vs parallel, no kubelet |
| `slodur.sh` | `podStartSLOduration`, the kubelet measuring itself |
| `knobs.sh` | the two kubelets' concurrency-bounding configuration, side by side |

Added while chasing the concurrency gap:

| | |
|:--|:--|
| `ab.sh` | alternating burst A/B with free memory logged, for when runs minutes apart disagree |
| `criconc.sh` | RunPodSandbox serial vs concurrent, via crictl, no kubelet |
| `criseq.sh` | when the kubelet *issued* each CRI call, from containerd's log |
| `stall.py` | what containerd logged inside the biggest gap between requests |
| `syncbatch.sh` | how many batches the kubelet learns about a burst in |

Added while asking the kubelet directly:

| | |
|:--|:--|
| `podphases.sh` | runs a burst and reads the kubelet's own account of it, either stack |
| `syncphases.py` | inside syncPod at `--v=4`: which part is work and which is waiting for a turn |
| `statuslat.py` | phase=Running to the status stored in the API, the part after syncPod |
| `apiwrite.py` / `apiwrite.sh` | what one sequential API write costs from inside a node |

## Inside syncPod, both stacks at --v=4

The kubelet's log level is a runtime setting now (`KUBELET_V=4` for the
harness, `FERRY_KUBELET_V=4` for ferry on its own, a kubeadm patch for kind), so
the question the last round stopped at, which phase stretches, can be put to
both kubelets directly. `podphases.sh ferry|kind` runs the burst and
reads the answer back.

20 pods, one round each, both nodes v1.37.0:

| median, ms | ferry | kind |
|:--|--:|--:|
| admit → SyncPod enter | 5 | 2 |
| wait → populator noticed | 43 | 13 |
| populator → verify attached | 101 | 105 |
| verify → mount started | 103 | 106 |
| **mount → mounted (the actual work)** | **10** | **10** |
| mounted → all mounted | 64 | 68 |
| all mounted → create sandbox | 1 | 3 |
| create → sandbox created | 204 | 155 |
| sandbox created → SyncPod exit | 231 | 157 |
| TOTAL admit → SyncPod exit | 779 | 630 |

### The projected serviceaccount volume is not where ferry loses

**The volume wait is 301ms on ferry and 301ms on kind, and 10ms of it is the
mount.** The other ~290ms is three sleeps: the populator's loop notices the
volume, the reconciler's next tick verifies it, the tick after that mounts it.
Writing the token and renaming it into place is 3% of the wait on both stacks.

That changes the previous round's lead. `NOSA=1` does halve ferry's spread,
and the reason is not that ferry's volumes are expensive. They are exactly as
expensive as kind's. Both stacks are paying the same fixed wait, and the
earlier "about half of it is the serviceaccount volume, and ferry has twice as
much to lose" reads the shared part as ferry's. Those four columns
were flagged provisional for being taken minutes apart; this is the other
reason to be careful with them.

### Where it actually goes is sandbox creation, under concurrency

Splitting the burst by admit order, `create → sandbox created`:

| | first half | second half | stretch |
|:--|--:|--:|--:|
| ferry | 95ms | 356ms | **+261** |
| kind | 121ms | 187ms | +65 |

Ferry's first pod gets a sandbox *faster* than kind's and its last takes
nearly twice as long. That is the same shape the wall-clock numbers have, now
located. Everything upstream of it is flat: `mount`, `mounted` and
`allmounted` are reached within ~110ms of each other across all twenty pods.

`HOSTNET=1`, which skips CNI entirely, moves that stretch from +261 to +180.
So CNI is part of it and not most of it, which agrees with the earlier finding
from the other direction.

These are single rounds, not alternated. Read the direction, not the
magnitudes, and re-run with `ab.sh`-style alternation before quoting them. The 301ms/10ms
volume figure is the exception: five separate runs across both stacks put it
between 300 and 301ms every time.

### The part worth acting on

Those three sleeps are `reconcilerLoopSleepPeriod` (100ms),
`desiredStateOfWorldPopulatorLoopSleepPeriod` (100ms) and
`podAttachAndMountRetryInterval` (300ms) in
`pkg/kubelet/volumemanager/volume_manager.go`. All three are unexported
package constants. No flag reaches them, no KubeletConfiguration field
reaches them, and every cluster pays them, including kind, which runs the
stock binary.

ferry does not have to. It already compiles its own kubelet from a whole-file
overlay in `patches/kubelet-vX.Y/`, which is the same mechanism this would
use. ~250ms is on the critical path of *every* pod start, burst or single, and
ferry's single pod is 541ms. A one-node developer cluster has no reason to pay
it.

The catch is that this only reaches mode 1 today. Mode 2's guest kubelet is
the upstream linux binary that `experiments/17-node-vm/stage.sh` downloads,
not one ferry builds.

## Taking the 300ms out, and what it was worth

This is done in `build-kubelet.sh`. The three constants are rewritten in place
(10ms, 10ms, 20ms), and the build fails if any of the three does not take.
Otherwise a constant that upstream renames would put the build silently back at
upstream's pacing and show up as a regression nobody could find.
`FERRY_VOLUME_RECONCILE_MS`, `FERRY_VOLUME_POPULATE_MS` and
`FERRY_VOLUME_RETRY_MS` override them.

Single pod, `timeline.py`, all v1.37.0, before and after on one machine in
one session:

| single pod, apply to Running | before | after |
|:--|--:|--:|
| ferry mode 1 (the patched kubelet) | 710ms | **431ms** |
| ferry mode 2 (guest kubelet, *not* patched) | 501ms | 497ms |
| kind (stock kubelet) | | 500ms |

**279ms off mode 1, and mode 1 now starts a pod faster than kind does.**

Mode 2 is the control. Its kubelet is the upstream binary the node image
downloads, nothing about it changed, and it did not move, so the 279ms is the
patch and not the machine having a quieter afternoon. The kubelet's own log
agrees from the inside. The volume wait on
mode 1 is **30ms, of which 3ms is the mount**, against the 301ms/10ms it and
both other stacks measured before.

This is the default path. `ferry up` is mode 1. Mode 2 is opt-in behind
`ferry machines enable`.

### Mode 2 as well

`build-kubelet-linux.sh` builds the guest kubelet from the same source with
the same rewrite and nothing else, into `experiments/17-node-vm/stage/`, where
`stage.sh` would otherwise download upstream's. It is deliberately not
`build-kubelet.sh` with a different `GOOS`. That script exists to make a
kubelet run on macOS at all, and none of its darwin shims belong in a Linux
build. It leaves a `kubelet.ferry-built` marker, because the two binaries are
otherwise indistinguishable and a stale one would read as a regression
somewhere else.

Single pod, `timeline.py`, n=7, everything v1.37.0, one machine one session:

| single pod, apply to Running | before | after |
|:--|--:|--:|
| ferry mode 2 | 501ms | **229ms** |
| ferry mode 1 | 710ms | **406ms** |
| kind | 500ms | 500ms |

**Mode 2 starts a pod in under half the time kind does.** The guest kubelet's
own log agrees: the volume wait there is 41ms, of which 16ms is the mount,
against 301ms/10ms before.

## What this did not fix: the burst

Three alternating rounds of 20 pods, after the patch:

| 20-pod burst | ferry mode 2 | kind |
|:--|--:|--:|
| first pod | 743ms | **627ms** |
| last pod | 1080ms | **877ms** |

Against ferry's own pre-patch runs in the same session (last pod 1183ms and
1186ms), the tail moved about 100ms. **kind still wins the 20-pod burst, and
the single-pod win does not carry over to it.**

What did change is the shape. Inside syncPod the staircase is gone:

| mode 2, 20-pod burst | before | after |
|:--|--:|--:|
| TOTAL admit to SyncPod exit, early pods | 655ms | 655ms |
| TOTAL admit to SyncPod exit, late pods | 892ms | 677ms |
| the stretch | +245 | **+22** |
| `create` to `sandbox created`, early | 95ms | 258ms |
| `create` to `sandbox created`, late | 356ms | 262ms |

Before, the volume loops released pods into the runtime a few at a time over
~400ms, and each wave found containerd freer than the last, so the early pods
looked fast and the late ones slow. Now all twenty arrive together and every
one of them takes the same 260ms. The work did not get cheaper. It stopped
being staggered, which is why the tail improves and the first pod does not.

### The lead that replaced the old one, and where it went

Splitting the container half of syncPod (`syncphases.py` now has
`CreateContainer` and `StartContainer` separately) put the gap in
`CreateContainer`: 265ms on ferry against kind's 35ms. It is not CNI.
`hostNetwork`, which skips it entirely, moves `create` to `sandbox created`
by 3ms (259 against 262). It is not CPU either. The burst comes out the same
with the machine at 10 CPUs and at 16.

`CreateContainer` is snapshot creation plus a bbolt transaction, which means
fsync, and from there it stopped being about the runtime at all.

## It was fsync on APFS, in two places

### The node disk

`FERRY_NODE_DISK_SYNC` makes the VM's disk barrier configurable. At `none`,
`CreateContainer` went 265ms to 162ms and the kubelet's whole span 682ms to
497ms.

At that point the kubelet stopped being the problem. The table has two spans,
each a duration inside one clock, so guest and Mac disagreeing about the time
does not enter into it:

| 20-pod burst | ferry | kind |
|:--|--:|--:|
| client span (first pod object seen to last pod Running) | 975ms | 807ms |
| kubelet span (first admit to last container started) | **516ms** | 706ms |
| outside syncPod | **459ms (47%)** | 101ms (13%) |

**ferry's kubelet was already 190ms faster than kind's and still losing.**
`podphases.sh` computes that residual now, because it is not visible in any
table that only looks inside the kubelet.

### etcd, which is the bigger one

The residual is the status manager. The kubelet decides phase=Running, and a
client is waiting on that reaching the API.
`statuslat.py` measures it.

| phase=Running to status stored | ferry | kind |
|:--|--:|--:|
| median | 188ms | 8ms |
| first half to last half | 85 to 294ms | 4 to 27ms |

It is a staircase, because the status manager drains its queue from one
goroutine. It is not client-side throttling, since neither kubelet logs a
single wait.

Every one of those writes is an etcd write, and ferry's etcd runs natively on
macOS:

| etcd, mean | ferry | ferry `--unsafe-no-fsync` | kind |
|:--|--:|--:|--:|
| WAL fsync | 4.85ms | none | 0.88ms |
| backend commit | 11.12ms | **0.12ms** | 1.78ms |

**kind's etcd is not better tuned. It is compiled for a different kernel.**

macOS has two durability calls. `fsync(2)` hands the data to the OS, and
`fcntl(F_FULLFSYNC)` flushes the drive's write cache. Go's `os.File.Sync()` is
the second on darwin and the first on linux. etcd is written in Go.

| same Mac, same SSD | |
|:--|--:|
| `fsync(2)` natively | 0.031 ms |
| `fcntl(F_FULLFSYNC)` natively | **3.961 ms** |
| `fsync(2)` in Docker's VM | 0.042 ms |

3.961 ms is the 4.85 ms etcd reports, less etcd's own work. The first version
of this finding said Docker had relaxed the host-side durability, which is
true of the disk image but is not the mechanism. Plain fsync costs the same
on both sides. The probe written to confirm it disproved it, which is the
only reason the right answer turned up.

`FERRY_ETCD_NO_FSYNC=1` opts in. It is off by default, because this is the
cluster's data, and a Mac that loses power mid-write can leave it needing a
restore.

etcd's own writes were not the only ones paying. `CreateContainer` happens
*in the guest* and dropped from 231ms to 59ms when the flag went on, with
nothing else changed. An F_FULLFSYNC on APFS flushes the device cache and
stalls whatever else is queued on that volume, the VM's disk image included.
One process's barriers were slowing another process's kernel.

## Where it ends up

Three alternating rounds of 20 pods, everything v1.37.0, CPUs matched:

| 20-pod burst | ferry mode 2 | kind |
|:--|--:|--:|
| first pod | **277ms** | 665ms |
| median pod | **494ms** | 758ms |
| last pod | **875ms** | 906ms |

| single pod | ferry mode 2 | kind |
|:--|--:|--:|
| apply to Running | **178ms** | 500ms |

This PR opened at 742ms first and 1400ms last, against kind's 786ms and
975ms. The last pod has gone from 1.44x behind to slightly ahead, and ferry
leads every earlier pod by a wide margin.

## The last of it: the kubelet was rate-limiting itself

What was left after both fsync barriers was not in the kubelet and not in the
runtime. The kubelet had all twenty containers started within 55ms and the
last pod's status was not stored for another 580ms.

Every plausible cause was measured and ruled out:

| hypothesis | result | how |
|:--|:--|:--|
| the write crosses vmnet to the Mac | **No.** A sequential PATCH from inside ferry's node is 2.07ms; from inside kind's node, 2.02ms. Identical. | `apiwrite.sh` |
| the guest is told the wrong address | No. The vmnet gateway is no faster than the Mac's LAN address (2.21 vs 2.07ms) | `apiwrite.sh` |
| etcd again | No. 0.12ms a commit with the barrier off | etcd metrics |
| client-side throttling, visibly | No. Neither kubelet logs a single wait, and client-go only logs one over 50ms | grep |
| ferry does more status writes | No. Three per pod on both | `statuslat.py` |

So the writes were the same speed and there were the same number of them.
What differed was the spacing:

| the one status write per pod that carries Running | ferry | kind |
|:--|--:|--:|
| gap between consecutive pods | **39.6ms** (min 2.7, max 41.7) | 4.2ms |
| span for twenty | 580ms | 198ms |

Nothing is that regular by accident. `kubeAPIQPS` defaults to 50, which is one
token per 20ms, and the status manager spends two per pod. So a rate limiter
paces a burst at 40ms a pod, with the containers long since running.

Upstream's defaults are right for a node that is one of hundreds, where a
kubelet flooding the API server is a real hazard. A ferry cluster is one or
two nodes and an API server on the same Mac. Raised to 500/1000, on both the
Mac's kubelet and the guest's, overridable with `FERRY_KUBE_API_QPS` and
`FERRY_KUBE_API_BURST`:

| 20-pod burst | before | after |
|:--|--:|--:|
| gap between status writes | 39.6ms | **2.2ms** |
| all twenty statuses stored within | 584ms | **75ms** |
| last pod Running | 875ms | **347ms** |

## Where it ends up

Three alternating rounds, 20 pods, everything v1.37.0, CPUs matched:

| 20-pod burst | ferry mode 2 | kind |
|:--|--:|--:|
| first pod | **293ms** | 632ms |
| median pod | **325ms** | 700ms |
| last pod | **347ms** | 886ms |
| spread across the burst | **55ms** | 254ms |

| single pod, apply to Running | ferry mode 2 | ferry mode 1 | kind |
|:--|--:|--:|--:|
| | **~190ms** | ~405ms | 500ms |

This PR opened with ferry's first pod at 742ms and its last at 1400ms,
against kind's 786ms and 975ms, and the last pod losing 1.44x. The last pod
is now 2.6x ahead, and the twenty of them finish within 55ms of each other.

### What is actually left

Nothing in this chain is the top cost any more. The remaining ~290ms before
the first pod is object creation and scheduling (~90ms of it) plus the
sandbox and container work, which is now flat across the burst rather than a
staircase. There is no queue left to find. The next real gain would have to
come from making the runtime itself faster, not from removing a wait.

## Teardown

`ferry down --purge` was 3.9s in mode 1 and 8.1s in mode 2, against kind's
0.47s. Timed per printed step, almost none of it was work.

| mode 1, 3.9s | |
|:--|--:|
| fixed `sleep 1` after the service proxy | ~1000 ms |
| ferry-cri releasing its vmnet network | ~500 ms |
| **the control plane** | **~2200 ms** |
| six other components, 11-29ms each | ~90 ms |
| purge | ~20 ms |

Inside the control plane, kube-scheduler and kube-controller-manager exit in
**0ms**. All of it is kube-apiserver draining its watches. That is 2.2s in
mode 1. In mode 2 it does not finish inside the 5s grace and is killed anyway,
which is where that stack's extra four seconds went.

There were three causes, all of them waiting rather than working:

- **The drain runs even when the data is about to be deleted.** `--purge`
  removes `$STATE/etcd` a few milliseconds later, so the API server was
  settling state that was about to be deleted. `--purge` now stops it without
  the drain. A plain `ferry down` keeps it, because that cluster is meant to
  come back. Checked by writing a configmap, running `ferry down`, bringing it up
  and reading the configmap.
- **Every teardown loop polled at 0.5s** for processes that exit in tens of
  milliseconds. `ferry_await_exit` and `ferry_await_gone` poll at 50ms with
  the same ten seconds of patience.
- **A fixed `sleep 1`** for ferry-proxy. Replacing it with an ordinary wait
  made teardown *about three times worse* (3.9s to 12.9s). ferry-proxy does not
  exit on SIGTERM at all, and the `sudo pkill` further down is what has always
  ended it. It gets 250ms and then the kill that was always coming.

| purge teardown | before | after |
|:--|--:|--:|
| mode 1 | 3940 ms | **350 ms** |
| mode 2 | 8100 ms | **540 ms** |
| kind, for scale | 470 ms | 470 ms |

It took three rounds. The first two are above. The third is that the
components were stopped one at a time, seven of them at ~70ms each, and the
control plane after all of them, though on `--purge` nothing between the two
needs an API server. Signals now go out in the order they have to and the
waits overlap, and the control plane goes down alongside the components
rather than behind them. `withdraw_gpu` is skipped on `--purge` for the same
reason. It patches a node that is about to stop existing, and it would race
the API server on its way down.

The number being chased was wrong. raw.tsv had mode 1's
delete at 0.85s and three clean runs of the same measurement put it at
0.46-0.49s, already level with kind, before any of the third round was
written. One run per stack is what this battery does and that cell was an
outlier. The work was still worth doing, but "we are losing by 0.4s" was
never true.

What is left is real: ~70ms a component to stop and be seen to stop, 137ms
for ferry-node to give back its vmnet network, 149ms for the control plane.

The general lesson is the one from the rate limiter. A very regular number is
a policy, not a cost. Half-second ticks and a one-second sleep are both
somebody's round number, and neither had been measured against what it was
waiting for.

## Cluster creation

Mode 2 was 32.6s. Timed per printed step, three things stood out, none of them
work.

### `ferry up` had teardown's problem

Five steps of `ferry up` landed within 43ms of each other at roughly half a
second: the GPU offer, the streaming server, kube-proxy, NetworkPolicies and
storage. That is a poll interval, not a cost. The control plane had three
more in `control-plane/up.sh`, at whole seconds: etcd's health check, the API
server's `/livez`, and its `/healthz`.

| | before | after |
|:--|--:|--:|
| GPU offered | 526 ms | 67 ms |
| streaming server | 512 ms | 58 ms |
| kube-proxy | 549 ms | 94 ms |
| NetworkPolicies | 533 ms | 56 ms |
| control plane | 4608 ms | 3561 ms |

### Eight seconds of diagnostics on the critical path

The kubelet cannot report `NetworkReady` until a CNI configuration exists, and
in the guest that file is written near the bottom of `init.sh`. It came after a
`sleep 8` whose only job is to log the default route, the API server's
`/healthz` and whether the kubelet is still alive, so that a node which cannot
join says so early instead of after a three-minute timeout.

That logging is useful, but the node's readiness should not wait for it. It
runs in the background now, and the podCIDR fetch below it polls at 0.2s rather
than 1s because the answer comes from kube-controller-manager's node-ipam
controller on a cold control plane.

| mode 2 | before | after |
|:--|--:|--:|
| Machine running to node Ready | 7.09 s | **0.07 s** |

### A port that was never shifted

`ferry-karpenter` binds 8081 for its health probe. Every other port ferry uses
is shifted by the profile's index. This one was not, so a second ferry on the
same Mac panics with `bind: address already in use`, which shows up as
"ferry-karpenter did not start; machines must be declared by hand" 4.6s into
`machines enable`. Mode 2 then falls back to hand-declared machines.

It was found because a stray karpenter from an earlier run in this session was
holding the port, which had been inflating mode 2's creation time in every
measurement taken here. It is the same problem as the default-profile etcd in
docs/BENCHMARKING.md, a fixed port on a machine that runs more than one
ferry.

### Where it ends up

| create a cluster | before | after |
|:--|--:|--:|
| mode 1 | 12.3 s | 12.3 s |
| mode 2 | 32.6 s | **25.9 s** |

Mode 1 does not move. Its polling savings are real but small against the two
items below, which it also pays.

### What is left, and why it was left

`ferry up` is now about 12s, and the largest piece of it is not ferry's. From
kube-controller-manager's own log, it starts at 21.920 and its **deployment
controller starts at 29.384**. That is 7.46s spent initialising some forty
controllers serially, with a worst single gap of 1.6s and no one cause. CoreDNS is a
Deployment, so its pod cannot be created until that controller is running,
which is why "cluster DNS" reads about five seconds even though the pod itself
goes from Pending to Ready in 848ms and the image pulls in 586ms. On a warm
cluster the same rollout is 598ms end to end.

Shortening it means `--controllers=<list>`, running fewer than upstream
enables. That is a behaviour change with a long tail. A controller nobody
thought about not running is a feature that silently does not work, so it is
written down here rather than done.

And it is not where ferry loses, because ferry does not lose here. kind's
controller-manager takes **8.89s** from starting to running its deployment
controller against ferry's **7.46s**, on the same machine and the same
Kubernetes. Both pay it; ferry pays slightly less.

What differs is when each tool stops talking to you. `kind create cluster`
returns after 7.7s with the cluster unusable for another 18.9s. `ferry up`
returns after 12.7s and is done 0.3s later. To a cluster that works it is
12.9s against 26.6s. The 7.5s above is real and is spent inside both numbers.
kind's comes after the prompt has come back.


## Running it

```sh
./run.sh ferry        # mode 1
./run.sh ferry2       # mode 2 — brings mode 1 up first, then a Machine
./run.sh kind
./run.sh minikube
python3 summarize.py results/raw.tsv

./m2mem.sh
./altbench.sh 4

# The kubelet's own account of a burst. Both stacks have to be at --v=4:
# KUBELET_V=4 stack_up, or FERRY_KUBELET_V=4 ferry up for ferry alone.
./podphases.sh ferry
./podphases.sh kind

# Faster, at the cost of durability nobody local needs. Both off by default.
FERRY_ETCD_NO_FSYNC=1 FERRY_NODE_DISK_SYNC=none ferry up
```

One stack at a time. `run.sh` appends to `results/raw.tsv`, so archive or clear
that directory between runs. `FERRY` is found relative to this directory and can
be overridden.
