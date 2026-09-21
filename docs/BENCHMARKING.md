# Benchmarking ferry against kind and minikube

**Read this before you measure anything.** Most of what follows is not about
ferry. It is about the ways this particular comparison produces confident,
publishable, wrong numbers — and how each of those was caught. Every mistake
below was actually made, most of them more than once, and several survived long
enough to be written up as findings before something contradicted them.

The harness is [`experiments/24-benchmark-harness/`](../experiments/24-benchmark-harness/).
[Experiment 21](../experiments/21-density-vs-kind-minikube/FINDINGS.md) is the
earlier, smaller version of the same comparison and reached the same conclusion
about memory from the other direction.

## The one rule

**ferry and the container stacks do not keep their memory in the same place, and
no single instrument reads both.** Everything else in this document follows from
that. A pod under ferry mode 1 is a macOS process; a pod under kind is a process
inside Docker Desktop's VM. There is no measurement that is native to both, so
every comparison is between two instruments, and the job is to make sure they
are at least measuring the same *kind* of thing.

Get this wrong and the error is not small. It inverted the headline result twice
in three runs.

## What goes wrong

### `vmmap` saturates, and it does so silently

`phys_footprint` from `vmmap --summary` is the right number for a macOS process
— it is what the OS charges, resident minus the shared pages every VM process
maps its own copy of. It is also useless above a certain size.

Docker Desktop's VM reported **exactly 14,848.0 MiB in every phase of every
stack** — baseline, idle, and at twenty pods, for both kind and minikube. That is
`vmmap` pinned to the allocation of a VM sized at 16 GB. It never moved because
it *cannot* move. If you difference it you get zero, and zero looks like a
result.

It is also coarse well below that: roughly 100 MiB resolution on large
processes, which is larger than several of the effects being measured.

> **Use it for ferry's VMs, which are small enough to resolve. Never use it for
> Docker's.**

### The two bases are not interchangeable

Because `vmmap` fails on Docker, kind and minikube have to be read from *inside*
the guest — `docker run --rm alpine free -m`, reporting the VM's own
`/proc/meminfo`. That is the honest number for them.

The trap is then charging ferry host-side while charging kind guest-side. That
is not conservative, it is **biased against ferry**, and by a factor of three:

| mode 2's node, at idle | |
|:--|--:|
| host-side `phys_footprint` | 1,405 MiB |
| used inside the guest | 406 MiB |

The ~1,000 MiB difference is guest page cache the host is still backing. Both
numbers are real and they answer different questions. Mixing them produced the
claim *"mode 2 has the highest idle memory of the four"* — which reversed
completely once mode 2 was read on kind's basis, where it has the **lowest**.

The same mixing produced *"mode 2 repays its floor against kind at ~100 pods."*
On a common basis it never crosses at all: 406 + 8.1n against 712 + 13.1n is a
lower floor *and* a lower slope.

**So:** where a shared guest exists, read inside it, for every stack. Mode 1 is
the one exception and has to be — its pods are separate VMs with no shared guest
to read. Say so wherever its line appears next to the others.
`m2mem.sh` does this for mode 2; `lib.sh:docker_guest_used_mib` does it for
Docker.

### A per-pod slope that swings 19× is telling you the basis is wrong

Mode 2's per-pod memory, charged as VM footprint, read **7.3 MiB** on one run and
**140.7 MiB** on the next. Same measurement, same harness, same machine.

Nothing about mode 2 changed by 19×. What changed was how much page cache the
guest happened to be holding, because VM footprint tracks that rather than pods.
Read inside the guest it is 7.9 MiB at ten pods and 8.1 at twenty — stable, and
consistent with the earlier figure.

**A number that moves by an order of magnitude between runs is not a noisy
measurement of the right thing. It is a measurement of the wrong thing.** That
swing is what exposed the basis error; without two runs to compare it would have
shipped.

> **Later correction.** Page cache may not be the cause. The battery was also
> scheduling half of ferry2's pods onto the Mac node as mode-1 VMs -- see
> "With mode 2 on, an unpinned pod is not a mode-2 pod" below -- and a varying
> mode-1 share explains a varying per-pod figure at least as well. The
> conclusion to draw from the swing is unchanged: the number was measuring
> something other than what it claimed.

### `ps %cpu` is not a CPU measurement

It is a decaying average over the process's *lifetime*. For a process that has
been up for hours it barely responds to what is happening now, and for a process
seconds old it is dominated by startup. Both appear in this comparison at once.

Use cumulative CPU-time deltas instead — `ps -o time`, sampled at the two ends of
a fixed window. `lib.sh:cpu_of` does this over 60s.

### A shared Docker Desktop poisons every Docker-side number

If anything else is running in Docker — and on a working machine, something
always is — its VM's CPU and memory are not attributable to the cluster under
test.

On the machine used for the 1.37 run, Docker Desktop was hosting three unrelated
containers. Its VM sat at **73–80% CPU with every cluster down**, and kind's
"cluster up" reading came in at 71.7% — *below* its own baseline. That is not a
noisy measurement of a real effect; it is unusable, and the whole column was
withdrawn rather than reported.

Memory survives this better than CPU, because a before/after delta around the
cluster's lifetime still means something. CPU does not, because the neighbours'
load moves on its own timescale.

> **Check what is in Docker before you start.** Either stop it, or report only
> deltas, or withdraw the column. Do not report an absolute.

### Host memory pressure inflates everything

Check before starting, not after:

```sh
vm_stat | awk '/Pages free/{f=$3} /occupied by compressor/{c=$5} \
  END{printf "free %.1fG  compressed %.1fG\n", f*16384/1e9, c*16384/1e9}'
sysctl -n vm.swapusage
```

The 1.37 run started at 9.0 GiB compressed with 1.3 GiB of swap in use. Absolute
memory figures are noisier under that, and it is the most likely explanation for
the one anomaly in that run (mode 2's ten-pod time coming out slower than its
twenty-pod time).

### The observer effect is enormous here

Sampling a profiler five times a second turned a **5.5-second burst into 91
seconds**. A sampler driven by iteration count rather than wall time wrote
10,962 dumps in 75 seconds, because `ctr pprof` returns in about 7 ms and the
loop had nothing to throttle it.

Pod start is a sub-second event on every one of these stacks. Anything sampling
faster than about 1 Hz is measuring itself.

> Prefer **one dump at a chosen moment** over a time series. If you need the
> series, take it on a run you have already agreed not to quote timings from.

### One measurement at a time. Actually one.

The single most expensive mistake in this whole effort: a ten-burst background
task was still running during a later kind run, the "clean" run after it, and the
A/B after that. Three sets of numbers were reported before the overlap was
noticed, and a conclusion — *"a 0.41s gap, and the ranges do not overlap"* — had
to be retracted.

Before every measurement:

```sh
ps -Ao command= | grep -cE '[a]ltbench|[b]ench/run.sh|[m]2mem'
```

Zero, or do not start. (Note the `[a]` bracket — see below, it matters.)

### `pgrep -f` matches the waiter's own command line

```sh
until ! pgrep -f "ferry build" >/dev/null 2>&1; do sleep 20; done   # never exits
```

`pgrep -f` matches full command lines, and this shell's command line contains
the string `ferry build`. It waits for itself. Three of these ran for eight and a
half hours before being noticed, and because a stuck waiter is indistinguishable
from work in progress, they read as "still building."

```sh
until ! pgrep -f "[f]erry build" >/dev/null 2>&1; do sleep 20; done  # correct
```

The bracket makes the pattern not match its own literal text.

This bites specifically when the loop is passed **inline** — `bash -c '...'`, or
a background one-liner — because then the pattern is part of the shell's own
command line. A script file is safe: `bash waiter.sh` puts only the filename
there, which is why the `pgrep -f` calls in this harness do not need the bracket.
Use it in every inline guard of this shape.

### Warm-up is real, and a single ordering hides it

Mode 2's twenty-pod burst improved monotonically across four alternating rounds —
1.83, 1.63, 1.59, 1.54s — while kind's did not. A battery that runs each stack
once, in a fixed order, cannot see that: it charges the first stack a warm-up it
never charges the last.

This also produced the one number in the 1.37 run that does not behave — mode 2's
ten-pod time (3.63s) coming out *slower* than its twenty-pod time (2.72s),
because ten pods runs first.

**Alternate the stacks and repeat rounds.** `altbench.sh` does A/B/A/B with a
full teardown between and logs free memory beside each sample, so drift is
visible in the output rather than folded into the result.

### Version skew is a real term, not a footnote

Ferry, kind and minikube each default to a different Kubernetes minor, and the
differences are not cosmetic. `OnPodSandboxReady` landed in **v1.36**; without it
the kubelet waits out a PLEG relist for a sandbox nothing told it was ready, and
roughly one pod start in six picks up a full extra second.

That single API is the whole of the difference between mode 2's v1.34 spread
(0.83–1.95s) and its v1.37 spread (0.82s, five times out of five).

Pin all stacks to the same minor if the question is architectural. If you cannot
— minikube is hard to move off its default — say which column is not
version-matched, in the table, not in a footnote.

### "Apply to Running" includes a lot that is not the runtime

Before attributing a difference to ferry, check the phases. The kubelet logs its
own boundaries at `-v=4`; `phases.py` extracts admit → volumes → sandbox →
Running per pod.

Doing that killed two of my own findings:

- *"A 0.08s volume tax versus kind"* — there is none. The full volume phase is
  0.307s for mode 2 against 0.306s for kind. The mount itself is 3 ms; the rest
  is the kubelet's own 100 ms populator and reconciler periods, which both
  stacks pay identically.
- *"~2 seconds inside `RunPodSandbox`"* — no. Sandbox creation is 0.16s. The
  `-v=2` log simply does not carry the "Created PodSandbox" line, and its absence
  was read as duration.

Ferry already wins or ties every phase it controls: volume setup 0.307 vs 0.306s,
sandbox creation 0.063 vs 0.065s, container start 0.034 vs 0.045s. The remaining
gap is not in any of them.

### A burst's wall time is the last pod, not the typical one

Twenty pods reaching Running in 2.72s says nothing about whether they went
together or in a staircase. `burstshape.py` reports the spread inside the burst
and `spread.sh` answers the serialized-versus-parallel question directly. A
change that improves the median pod and not the last one does not move the
number you are reporting.

### With mode 2 on, an unpinned pod is not a mode-2 pod

The worst measurement error found so far, and it was in this harness for three
runs.

`ferry machines enable` gives the cluster **two nodes of different
architectures** -- the Mac node, where a pod is a VM with its own kernel, and
the machine node, where a pod is a container sharing one. A Deployment with no
`nodeSelector` is scheduled across both. Measured, with ten replicas and the
battery's own manifest:

```
  5 ferry-mac-...    vm-per-pod
  5 perf-0           shared
```

An even split. So every ferry2 row the battery produced was **half mode 1 and
half mode 2**, and the ratio moved from run to run with whatever the scheduler
scored. That single bug produced:

- *"mode 2 starts a pod in 0.82s against kind's 0.62s."* Watched rather than
  polled, and pinned, it is **541ms against kind's 544ms** -- a tie.
- *"mode 2's ten-pod time (3.63s) is slower than its twenty-pod time (2.72s),
  which should not happen."* It does not happen. That was the mixture changing
  between the two cells.
- Very likely the **19× per-pod memory swing** attributed above to guest page
  cache. Ten mode-1 pod VMs at ~220 MiB is 2,200 MiB, against an observed
  2,814 MiB at twenty pods, where a pure mode-2 burst costs ~8 MiB a pod. The
  page-cache explanation is not needed to account for it and the arithmetic
  fits the mixture better. Not yet confirmed by a dedicated run -- treat the
  cause as open, but do not trust the old number either way.

`stacks.sh:node_selector_of` now pins ferry2. `whereland.sh` is the check:
apply the battery's own manifest unpinned and print where the pods went.

> **The general form:** if a stack can put the work in more than one place,
> pin it, and have the harness *report* where it landed. `burst.py` prints the
> node histogram with every result for exactly this reason. A latency number
> with no statement of where it ran is not a measurement of an architecture.

### Watch, do not poll, when the thing you are timing is sub-second

The battery polls `kubectl get pods` until the count is right, so its
resolution is one iteration of that command -- **40.7ms against ferry and
48.5ms against kind** (`pollcost.sh`). On a 0.5s event that is 10% of the
answer, and it is not the same 10% for both stacks.

Polling was not what produced the wrong headline here -- ferry is the *faster*
of the two to poll, so the bias ran the other way -- but it is why the
battery's absolute numbers sit ~200ms above the watched ones. `timeline.py`
and `burst.py` watch the API instead, through `kubectl proxy`.

Two traps in doing that:

- `kubectl get pod <name> -w` on a pod that **does not exist yet exits
  immediately**, and the watch has to be established before the apply. Watch
  the namespace and filter by name.
- `kubectl get -w -o json` **block-buffers into a pipe**; events arrive long
  after they happened, or never. Going through `kubectl proxy` and reading
  newline-delimited JSON avoids it and handles both stacks' auth identically.

## vmnet, which will waste an afternoon

Two independent facts, both of which look like a ferry bug:

- **A subnet stays reserved after the process using it stops.** Documented as
  about a minute; observed far longer. An `enable` that follows a teardown is
  refused, and waiting is not reliable.
- **32 networks, system-wide.** Not per process. Everything else on the machine
  counts.

The harness sidesteps both by moving to a subnet this run has not used, tracked
in a counter file that survives the battery's own create/delete cycles
(`stacks.sh`, `ferry2` case). That was the fix that made a repeatable battery
possible at all. [Experiment 22](../experiments/22-vmnet-lifecycle/) is the
underlying investigation.

## Things that were measured and rejected

Recorded so nobody re-runs them hopefully.

| Hypothesis | Result |
|:--|:--|
| `EventedPLEG: true` closes the burst gap | **Worse**, in both regimes. 1.81 → 3.76s before the fsync fix; 1.99/6.18/6.07s after. `pleg.sh` |
| `serializeImagePulls: false` helps | No measurable effect |
| The gap is CPU | No. Mid-burst the guest used 48% of *one* core out of ten |
| The gap is the CNI path | No. `hostNetwork` pods, which skip CNI entirely, do not close it |
| The gap is volume setup | No. 0.307s vs kind's 0.306s |
| The gap is API round-trip latency across the host/guest boundary | No. 1.15ms from inside ferry's node against kind's 0.84ms, and a pod start makes nothing like the 645 round trips that would need. `rtt.sh` |
| The gap is the control plane or the scheduler | No. All 20 pods of a burst are created by 142ms and scheduled by 152ms. `burst.py` |
| The gap is the durability barrier, still | No. fsync costs 0.085ms inside ferry's node against kind's 0.098ms -- the `.fsync` change fixed it thoroughly. `fsynccost.sh` |
| The gap is containerd serializing | No. 20 containers in 165ms with a 6x speedup from concurrency, kubelet not involved. `ctrconc.sh` |
| The gap is kubelet configuration | No. Neither sets kubeAPIQPS/Burst, and ferry uses cgroupfs where kind uses the slower systemd driver. `knobs.sh` |
| The battery's poll loop is biased against ferry | No. It costs 40.7ms an iteration against ferry and 48.5ms against kind. `pollcost.sh` |

## Two real causes, for reference

Both were found by instrumenting rather than reasoning, and both are fixed.

**No entropy device.** `rng_available` was empty and `crng init done` took
**10.036679s**. Adding `VZVirtioEntropyDeviceConfiguration` took it to
**0.074620s**, and node registration from 12,493 ms to 8,219 ms. This is also
what made `ctr` appear to hang for 17 seconds, and once for over six minutes.

**Every guest fsync was a full host barrier.** Ten goroutines parked on
containerd's `core/metadata` mutex mid-burst while the guest used less than half
a core. `VZDiskImageStorageDeviceAttachment(synchronizationMode: .fsync)` took
twenty pods from ~5.2s to ~2.2s.

The shape of both: a large, stable, *structural* delay that reasoning about
Kubernetes would never have found, sitting underneath the layer everyone
suspects.

## Running it

```sh
cd experiments/24-benchmark-harness

./run.sh ferry        # mode 1
./run.sh ferry2       # mode 2 — brings mode 1 up first, then a Machine
./run.sh kind
./run.sh minikube

python3 summarize.py results/raw.tsv
```

One stack at a time, sequentially, with teardown between. `run.sh` writes
`results/raw.tsv` as `stack<TAB>key<TAB>value`, appended — archive or clear the
directory between runs or two runs will be interleaved in one file.

Then, for the numbers the battery cannot get honestly:

```sh
./m2mem.sh            # mode 2's memory, read inside the guest
./altbench.sh 4       # 20-pod burst, mode 2 vs kind, four alternating rounds
```

`summarize.py` handles the baseline subtraction per stack and picks the right
instrument for each. It does **not** correct the ferry2 memory basis — that is
what `m2mem.sh` is for, and the two should be reported together.

## A checklist

Before:

- [ ] Nothing else measuring (`ps -Ao command= | grep -c ...`, expect 0)
- [ ] Host memory pressure noted — free, compressed, swap
- [ ] What is running in Docker Desktop, written down
- [ ] Kubernetes version of every stack, written down
- [ ] No profiler or sampler armed

After, for every number:

- [ ] Which instrument, and is the comparison stack on the same one
- [ ] Is it a delta from a baseline taken in the same conditions
- [ ] Does it survive a second run
- [ ] If it disagrees with a previous run by more than noise, which basis changed

And the habit that caught the most: **when a result is surprising, assume the
measurement before the architecture.** Every genuinely surprising number in this
effort was an instrument problem until proven otherwise, and most of them stayed
that way.
