# A repeatable battery against kind and minikube

[Experiment 21](../21-density-vs-kind-minikube/FINDINGS.md) answered this
question once, by hand. This is the same comparison made repeatable: one
interface per stack, one battery that runs against any of them, and the separate
instruments needed for the numbers the battery cannot get honestly.

**The methodology, and every way this goes wrong, is
[docs/BENCHMARKING.md](../../docs/BENCHMARKING.md). Read that first.** What
follows is the result of the third run.

## Results — 19–20 September 2026

Apple M1 Max, 10 cores, 32 GiB, macOS 26.6. ferry at `317b1c5`, kind v0.33.0,
minikube v1.33.1, Docker Desktop 4.48.0. Image `alpine:3.20`, pre-pulled.

Ferry's two modes and kind all ran **v1.37.0** — the first run where ferry and
kind were on the same minor. minikube's own default is still **v1.30.0**, so that
column is not version-matched.

> **The mode 2 latency rows below are wrong** — the battery scheduled half of
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
all three shared-kernel stacks. Mode 1 is the exception and has to be: its pods
are separate VMs with no shared guest, so its figures are summed
`phys_footprint`. See BENCHMARKING.md — mixing those two bases is the single
biggest error available here, and it inverted this table's memory rows on the
previous run.

The Docker-side CPU column was withdrawn: Docker Desktop was hosting three
unrelated containers, its VM sat at 73–80% with every cluster *down*, and kind's
"cluster up" reading came in below its own baseline. Ferry's own figures — 0.30%
mode 1, 6.40% mode 2 — stand, because its processes are individually
identifiable.

## What this says

**Against minikube, ferry wins across the board.** Mode 1 creates a cluster in
half the time, both modes start pods faster, mode 2 finishes a twenty-pod burst
in 2.72s against 3.69s, and costs half as much per pod. minikube's only win is
teardown. Discount for the version gap; the margins survive it.

**Against kind it splits.** Ferry wins the entry cost — 14.4s against 26.3s, the
largest margin in the battery — and wins memory on a common basis, where mode 2's
406 + 8.1n never crosses kind's 712 + 13.1n. Kind wins every latency number
involving a pod: 0.62s against 0.82s for one, 1.07s against 2.72s for twenty.

**That last sentence does not survive the correction below.** Pinned and
watched, the single pod is a tie and ferry's *first* pod of a burst is faster;
what kind wins is concurrency, at 11.3ms per additional pod against ferry's
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
   0.074620s; node registration from 12,493 ms to 8,219 ms.
2. **`synchronizationMode: .fsync`** on the node's disk, so a guest fsync stops
   being a full host barrier. Twenty pods went from ~5.2s to ~2.2s.
3. **Kubernetes 1.36+**, for `OnPodSandboxReady`. Mode 2's single-pod time went
   from 0.83–1.95s to 0.82s five times out of five — the full-second tail that
   hit roughly one start in six is gone.

## Caveats on this run specifically

- **Mode 2's ten-pod time (3.63s) is slower than its twenty-pod time (2.72s).**
  It should not be. A separate four-round alternating A/B showed mode 2
  improving monotonically (1.83, 1.63, 1.59, 1.54s) where kind did not, so there
  is a warm-up effect neither instrument isolates. Ten pods runs first. Reported
  as measured rather than dropped; do not read it as a per-pod cost.
- **The host was under memory pressure** — 9.0 GiB compressed, 1.3 GiB swap in
  use, before the battery started.
- **Latency is n=5**, memory a single measurement at rest. Only the twenty-pod
  burst has repetition behind it, via `altbench.sh`. No confidence intervals are
  claimed.

## Correction: the latency rows above were measuring two architectures at once

**Every ferry2 latency figure in the table above is wrong**, and the cause is
in this harness rather than in ferry.

`run.sh` interpolates `${NODE_SELECTOR}` into its Deployment and `stacks.sh`
never set it for `ferry2`. With mode 2 enabled the cluster has two nodes of
different architectures, so the pods were scheduled across both -- an even 5/5
split of ten replicas, measured with the battery's own manifest by
`whereland.sh`. Half of every "mode 2" burst was mode 1, booting a VM per pod.

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
`podStartSLOduration` shows the same shape from inside the node -- ferry's
fastest pod beats kind's (898ms against 970ms) and its slowest is far behind
(1559ms against 1233ms).

The ten-pod cell that the run above flags as an anomaly -- 3.63s against a
twenty-pod 2.72s -- is this bug, not a warm-up effect. The mixture differed
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

What remains is the CRI path as the kubelet drives it under concurrency --
sandbox, CNI, container, status -- which `ctr run` does not exercise. That is
where to look next.

## Where the concurrency gap is, and where it is not

The correction above leaves one real difference: ferry's first pod of a burst
beats kind's and its last loses badly. Three alternating rounds, 20 pods,
teardown between, free memory logged (`ab.sh` — taken after two runs minutes
apart disagreed by 187ms on a figure that had strictly *less* work to do):

| 20-pod burst, 3 alternating rounds | ferry | kind |
|:--|--:|--:|
| first pod (median) | **742ms** | 786ms |
| last pod (median) | 1400ms | **975ms** |
| marginal cost per additional pod | 34.6ms | **9.9ms** |

Ferry's first pod wins all three rounds; its last loses all three.

### The runtime is not the problem — it is the faster of the two

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
timings anyway — kind uses the systemd cgroup driver, and runc rejects a
`cgroup_parent` that is not a slice. The script now counts what it created and
says so. Same class of error as the `ctr` namespace mistake below.

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
427ms — and containerd is not idle during the gaps: `stall.py` shows it busy
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
ferry-specific — but ferry has roughly twice as much of it to lose, and is
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
directly; it currently needs a node-image rebuild to do that, which is worth
making a runtime flag.

## The scripts

The battery:

| | |
|:--|:--|
| `lib.sh` | measurement helpers — footprints, guest memory, cumulative CPU |
| `stacks.sh` | one up/down/kubeconfig interface per stack, and which host processes belong to each |
| `run.sh` | the battery, run once per stack |
| `summarize.py` | `results/raw.tsv` → the comparison tables |

What the battery cannot measure honestly, measured separately:

| | |
|:--|:--|
| `m2mem.sh` | mode 2's memory read inside the guest, on kind's basis |
| `altbench.sh` | 20-pod burst, mode 2 vs kind, alternating with teardown between |

Diagnostics, each answering one question:

| | |
|:--|:--|
| `phases.py` | per pod: admit → volumes → sandbox → Running, from the kubelet's own log |
| `burstshape.py` | the spread *inside* a burst — wall time is the last pod, not the typical one |
| `spread.sh` | do 20 pods start together, or in a staircase |
| `objrate.sh` | separates "the control plane created 20 objects" from "the node started them" |
| `m2-breakdown.sh` | where mode 2's idle memory goes |
| `m2-phases.sh` | where mode 2's bring-up time goes |
| `pleg.sh` | pod start with and without `EventedPLEG` (it is worse — see BENCHMARKING.md) |

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

## Inside syncPod, both stacks at --v=4

The kubelet's log level is a runtime knob now (`KUBELET_V=4` for the harness,
`FERRY_KUBELET_V=4` for ferry on its own, a kubeadm patch for kind), so the
question the last round stopped in front of — which phase stretches — can be
put to both kubelets directly. `podphases.sh ferry|kind` runs the burst and
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

That reframes the previous round's lead. `NOSA=1` really does halve ferry's
spread, and the reason is not that ferry's volumes are expensive — they are
exactly as expensive as kind's. Both stacks are paying the same fixed toll,
and the earlier "about half of it is the serviceaccount volume, and ferry has
twice as much to lose" reads the shared part as ferry's. Those four columns
were flagged provisional for being taken minutes apart; this is the other
reason to be careful with them.

### Where it actually goes is sandbox creation, under concurrency

Splitting the burst by admit order, `create → sandbox created`:

| | first half | second half | stretch |
|:--|--:|--:|--:|
| ferry | 95ms | 356ms | **+261** |
| kind | 121ms | 187ms | +65 |

Ferry's first pod gets a sandbox *faster* than kind's and its last takes
nearly twice as long — the same shape the wall-clock numbers have, now
located. Everything upstream of it is flat: `mount`, `mounted` and
`allmounted` are reached within ~110ms of each other across all twenty pods.

`HOSTNET=1`, which skips CNI entirely, moves that stretch from +261 to +180.
So CNI is part of it and not most of it, which agrees with the earlier finding
from the other direction.

Single rounds, not alternated — read the direction, not the magnitudes, and
re-run with `ab.sh`-style alternation before quoting them. The 301ms/10ms
volume figure is the exception: five separate runs across both stacks put it
between 300 and 301ms every time.

### The part worth acting on

Those three sleeps are `reconcilerLoopSleepPeriod` (100ms),
`desiredStateOfWorldPopulatorLoopSleepPeriod` (100ms) and
`podAttachAndMountRetryInterval` (300ms) in
`pkg/kubelet/volumemanager/volume_manager.go`. All three are unexported
package constants. No flag reaches them, no KubeletConfiguration field
reaches them, and every cluster in the world pays them — including kind,
which runs the stock binary.

ferry does not have to. It already compiles its own kubelet from a whole-file
overlay in `patches/kubelet-vX.Y/`, which is the same mechanism this would
use. ~250ms is on the critical path of *every* pod start, burst or single —
ferry's single pod is 541ms — and it is a toll a one-node developer cluster
has no reason to pay.

The catch is that this only reaches mode 1 today. Mode 2's guest kubelet is
the upstream linux binary that `experiments/17-node-vm/stage.sh` downloads,
not one ferry builds, so collecting it there means building a linux/arm64
kubelet from the same tree — which is not hard, and is a larger change than
this round should make on its own.

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
```

One stack at a time. `run.sh` appends to `results/raw.tsv`, so archive or clear
that directory between runs. `FERRY` is found relative to this directory and can
be overridden.
