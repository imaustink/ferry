# ferry against kind and minikube

Run on a Mac16,5, 128 GiB, macOS 26.6.2, with `./run.sh --pods 8`. One run per
stack, image `public.ecr.aws/docker/library/alpine:3.20`, pre-pulled.

kind v0.32.0, minikube v1.38.1 (docker driver), Docker Desktop 29.2.1,
ferry v0.1.0.

## What was fixed before anything started

**Docker Desktop: 15.6 GiB and 16 cpus, committed before the first pod exists.**
That is the whole of kind's and minikube's memory budget, taken whether it is
used or not. ferry allocates nothing up front. It creates a pod VM when a pod
is created.

## Results

| | up | first pod | teardown | memory |
|---|---|---|---|---|
| kind | 13.8 s | 10.3 s | 0.4 s | 2354 MiB *in the VM* |
| minikube | 21.4 s | 1.0 s | 11.4 s | 2200 MiB *in the VM* |
| **ferry**, mode 1 | **12.6 s** | **1.0 s** | 2.7 s | **1047 MiB of the Mac** |

With eight pods rather than one:

| | 8 pods | per extra pod |
|---|---|---|
| kind | 2342 MiB in the VM | ~0 |
| minikube | 2300 MiB in the VM | 14.2 MiB |
| **ferry**, mode 1 | 2705 MiB of the Mac | 236.8 MiB |

"Up" means *able to run a pod*, not *the command returned*. See the harness
bugs at the end.

## The two memory columns are not the same number, and cannot be

There is no way to measure what a pod costs the Mac under kind or minikube.
Their pods live inside Docker Desktop's VM, whose memory is committed when the
VM starts. Measured directly, allocating a gigabyte inside it moves no host
process's RSS by a single page. A `vm_stat` delta around a cluster start
therefore returns noise. The first version of this reported kind costing
**minus 210 MiB** for a cluster and a pod, which is how the problem was found.

That is not a measurement to work around. It is the difference between them:

- a pod on kind or minikube costs the Mac **nothing extra**, because the memory
  was taken in advance. It costs a slice of a fixed VM, and when that slice is
  gone, pods stop fitting.
- a pod on ferry costs the Mac **236.8 MiB**, and nothing is reserved before it.

So the report is two numbers labelled as what they are. One is what a pod takes
from the VM you committed, and the other is what a pod takes from the machine.

236.8 MiB per pod independently reproduces the 226 MiB measured by
[experiment 13](../13-shared-kernel-cost/FINDINGS.md) by a different method, on
a different day, which is the main reason to trust this harness.

## What the numbers say

**Starting is not where the difference is.** ferry is up in 12.6 s against
kind's 13.8 and minikube's 21.4. That is faster, but not by the margin the pod
numbers suggest, because a control plane coming up dominates all three, not
virtualization. Where ferry wins outright is that those 12.6 s include
*creating* the machine it runs on. kind's and minikube's exclude 15.6 GiB of VM
that had to exist first.

**A cluster costs 2.2–2.4 GiB before any workload.** kind and minikube both
spend that much of their VM on an idle single-node cluster. ferry's whole
footprint with a pod running is 1047 MiB of real memory. On a 16 GiB Mac,
Docker Desktop's default allocation is a substantial fraction of the machine,
and 2.3 GiB of it is gone before the first workload.

**Pods are nearly free inside an existing VM, and are not free on ferry.** Eight
`sleep` containers added nothing measurable to kind and 14 MiB each to minikube.
They cost ferry 237 MiB each. That is the price of a kernel per pod, and it is
the trade the whole project is about. It is a real cost, and anybody choosing
ferry mode 1 on a small Mac is choosing to spend memory on isolation.

## Caveats, and they matter

- **One run per stack.** No variance, no repeats. Treat differences under a
  second or a hundred MiB as noise.
- **kind's first pod at 10.3 s is suspect.** minikube did the same work in 1.0 s
  and ferry in 1.0 s. The harness pre-pulls the image into the node with
  `crictl pull`. If that did not take for kind, the 10.3 s includes a registry
  fetch and is not a scheduling measurement. It is reported as measured rather
  than dropped, but it should not be cited as kind being ten times slower to
  start a pod.
- **The Mac was not idle.** Docker Desktop, another minikube profile and a
  second ferry cluster were running throughout. ferry's numbers are host deltas,
  which subtracts a constant background. kind's and minikube's are read from
  inside their own VM, which is unaffected. CPU contention can affect the
  timings of either.
- **ferry mode 2 was not measured.** The harness kept being interrupted before
  it completed, and the numbers it would have produced are the interesting ones
  for the question of which mode should be the default. Until it is measured,
  [MACHINES.md](../../docs/MACHINES.md)'s figures from experiment 16, ~17 MiB
  marginal per container and ~45 ms to start one, are what is known. Neither
  answers whether a node VM's memory is lazily backed the way a pod VM's is.

- **Docker Desktop's allocation is this Mac's setting**, not a default. A
  smaller Mac would have a smaller VM, and less of it left after the 2.3 GiB
  baseline.

## Reproducing

```sh
./experiments/21-density-vs-kind-minikube/run.sh --pods 8
./experiments/21-density-vs-kind-minikube/run.sh --pods 8 --only ferry-mode1
```

It uses cluster names of its own (`ferrybench`, ferry profile `bench`) so it
cannot touch a cluster somebody is using, and names every `kubectl --context`
explicitly rather than depending on or rewriting the current one.

Three harness bugs are worth knowing about, because each produced a plausible
wrong answer rather than an error:

- `KUBECONFIG=""` is set-but-empty, which client-go reads as an explicit empty
  config rather than a fallback to `~/.kube/config`. kubectl found no cluster
  and it looked like a pod that never became Ready.
- `kind create cluster` returns before kube-controller-manager has created the
  `default` ServiceAccount, and a pod created in that window is rejected with
  `error looking up service account default/default`. "Up" is now measured to
  the point where a pod can actually be created, for every stack.
- macOS ships bash 3.2, where `"${arr[@]}"` on an empty array is an unbound
  variable under `set -u`. Only ferry hit it, because only ferry is addressed
  with an empty `--context`.
