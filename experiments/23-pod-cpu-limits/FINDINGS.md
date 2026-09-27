# Experiment 23: does a pod's CPU limit reach the cgroup inside its VM?

**Question.** ferry gives every pod a virtual machine and every container in it a
cgroup inside that machine. Those are two decisions made in two places. The
runtime sizes the machine at sandbox creation from the pod spec, and writes the
cgroup from what the kubelet puts in the CRI config. On darwin the
kubelet was putting `CpuShares: 0, CpuQuota: 0` there for every container. Was
that visible from outside, and does fixing it do what the arithmetic says?

**Method.** Seven pods spanning the cases, read two ways. Configuration is each
container's own `/sys/fs/cgroup/cpu.max`, read from inside it, against what its
spec asked for. Enforcement is four busy workers for five seconds in a container
allowed fewer than four CPUs, with the cgroup's own `cpu.stat` read before and
after. Configuring a quota and enforcing one are separate claims, and the
second is the one that matters.

`./run.sh` is the whole thing, and asserts rather than prints.

Four builds, to separate which half of the change does what:

| build | what it is |
|---|---|
| `main` | before any of this, `bca1648` |
| `kubelet only` | the rebuilt kubelet with `main`'s runtime. Not a commit; it happened by mistake and was worth keeping |
| `commit 2` | `6b3183c`, the first attempt at the runtime side |
| `final` | the PR as it stands |

Run on macOS 26.6, Apple M1 Max, 10 cores, 32 GiB. Kubernetes v1.36.4,
`FERRY_POD_CPUS=2`, `busybox` pods. `—` is not measured, not zero.

## Results

`cpu.max` quota, in microseconds against a 100000 period. `max` is no limit at
all. `nproc` is the VM's vCPU count, a different decision made elsewhere.

| pod | spec | main | kubelet only | commit 2 | **final** | nproc |
|---|---|---|---|---|---|---|
| `cpu-limit-2` | `limits.cpu: 2` | `max` | 200000 | 200000 | **200000** | 2 |
| `cpu-fractional` | `limits.cpu: 1500m` | `max` | 100000 | 100000 | **200000** | 2 |
| `cpu-sub-one` | `limits.cpu: 100m` | `max` | 100000 | — | **100000** | 2 |
| `cpu-two-containers` a, b | `limits.cpu: 1` each | — | 100000 each | — | **100000 each** | 2 |
| `cpu-besteffort` | nothing | `max` | `max` | 100000 | **`max`** | 2 |
| `cpu-request-only` | `requests.cpu: 1` | `max` | `max` | 100000 | **`max`** | 2 |
| `cpu-limit-4` | `limits.cpu: 4` | — | — | — | **400000** | 4 |

Three things in that table.

**Before, no container had a CPU limit at all.** Every reading under `main` is
`max`, including the pod that asked for two CPUs. `nproc` was right in every
case, which is why this went unnoticed for so long. A single-container pod could
use its whole machine, and its machine had been sized from what it asked for, so
it usually got roughly the right answer for the wrong reason. It only matters
when a pod has more than one container, or when the machine is bigger than the
container's limit. Two containers limited to `cpu: 2` each shared a four-vCPU
machine with neither held to its half.

**The floor under-granted.** `kubelet only` and `commit 2` both give the 1500m
pod a single CPU, a third less than Kubernetes said it could have. Whole CPUs
are the only unit a guest cgroup gives here, so `final` rounds up. It cannot
over-grant past the machine, because the VM is sized with the same rounding.

**The shares fallback capped what must not be capped.** Under `commit 2` both
the BestEffort pod and the request-only pod read one CPU. `MilliCPUToShares(0)`
returns `MinShares`, which is 2, so there is no value of `cpu.shares` that means
"no request". The fallback fired for every running container. `final` sets no
quota at all when there is no limit, which is what Burstable and BestEffort
mean.

## The quota is enforced, not just configured

Four busy workers for five seconds of wall clock, `final` build. Five seconds is
fifty 100ms periods.

| pod | quota | vCPUs | CPU-seconds used | periods throttled |
|---|---|---|---|---|
| `cpu-besteffort` | none | 2 | 10.0 | 0 |
| `cpu-sub-one` | 1 CPU | 2 | 5.0 | 50 |
| `cpu-limit-2` | 2 CPU | 2 | 10.0 | 0 |
| `cpu-fractional` | 2 CPU | 2 | 10.0 | 0 |
| `cpu-limit-4` | 4 CPU | 4 | 20.0 | 13 |

The 100m container was throttled in every period and delivered exactly the one
CPU it is allowed, against four workers asking for four. The BestEffort
container was throttled in none of them and took both its vCPUs. Those two rows
are the whole result. A limit binds, and the absence of one does not.

`cpu-limit-2` and `cpu-fractional` are not throttled because their quota is the
size of their machine. The hypervisor bounds them before the scheduler has
anything to say. `cpu-limit-4` is throttled occasionally for the same reason in
reverse. Four workers on four vCPUs sit exactly on the boundary.

## A second thing the run found

With pods running, the kubelet wrote two error lines per pod per sync:

```
kubelet_pods.go:2193] "failed to read memory cgroup config for the pod"
  err="not implemented" podName="cpu-limit-2"
kubelet_pods.go:2198] "failed to read memory cgroup limits for the pod"
  err="not implemented" podName="cpu-limit-2"
```

Six pods, twelve lines a minute, nothing wrong. `convertToAPIPodLevelResourcesStatus`
asks the pod container manager to read the pod's cgroup back on every sync and
only logs what comes back. The stub reports `not implemented`. ferry has no pod
cgroup, because the pod boundary is the VM, so the correct answer is *no
configuration, and no error*. Every caller already handles that, because Windows
has never had a pod cgroup either. `ferry_pod_container_manager_darwin.go` says so, and
the count after the same run is zero.

It does not weaken the one place that must refuse. In-place pod resize asks
`ResourceConfigForPod` for the configuration it would write before reading the
current one. That is `nil` on darwin, and `doPodResizeAction` still fails the
resize and names the reason.
 A VM cannot be resized after it boots.

## What this does not cover

- One node, one Mac. Nothing here says anything about a second node.
- Five seconds a pod. No soak, no thermal behaviour, no contention between pods
  competing for the same cores.
- Memory is not measured. The machine's memory sizing is experiment 13's
  subject; only its CPU count appears here.
- Nothing resizes. In-place pod resize is refused on darwin and stays refused.
- v1.36.4 only. The other three supported minors build and carry the same
  overlay, but the cluster was only driven on this one.
