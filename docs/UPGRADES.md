# Cluster upgrades

Moving a running cluster from one Kubernetes to another.

Before this, `ferry build --kubernetes-version` changed what a *new* cluster was
built from and nothing moved an existing one. There was also no "from" to move
away from: the kubelet's build version was recorded in the checkout, the control
plane's was not recorded anywhere, and the two had different defaults that
nothing reconciled.

```
ferry upgrade status          what is running, what is built, what can roll back
ferry upgrade plan <vX.Y.Z>   check an upgrade without doing any of it
ferry upgrade apply <vX.Y.Z>  move the control plane, keeping the cluster's data
ferry upgrade nodes           drain and replace each kubelet on this Mac
ferry upgrade node <name>     just that one
ferry upgrade rollback        back to the version before the last apply
```

## The shape of it

Upstream's, because the constraints are upstream's:

1. **The control plane first, and alone.** Four processes stop and start again
   against the same etcd data directory.
2. **Then each node, one at a time.** Drain it, replace its kubelet, wait for it
   to come back Ready, uncordon, move on.

Between those two steps the cluster is deliberately running mixed versions. That
is the supported state, and it is why the order is what it is: a kubelet may lag
the API server by three minors and may never lead it by one.

```
ferry upgrade plan v1.35.0     # changes nothing
ferry upgrade apply v1.35.0    # control plane
ferry upgrade nodes            # kubelets, when you like
```

There is no hurry between the second and third. A cluster left with a v1.34
kubelet and a v1.35 API server is a correct cluster, not a half-finished
upgrade.

## What ferry's design buys, and what it costs

**etcd's data outlives a restart.** It lives in `$FERRY_HOME/etcd` and
`ferry down` leaves it alone, so a control plane upgrade is a restart of four
processes rather than a migration. This is the whole reason an in-place upgrade
is possible.

**A node's runtime carries no Kubernetes version.** `ferry-cri` is ferry's own
code, so the kubelet is replaced without stopping the runtime. Pods that drain
did not move — a DaemonSet pod, anything that tolerates the drain — keep running
across the swap, because they are VMs the runtime owns and not something the
kubelet holds open.

**A checkout has one `bin/`.** Every node on one Mac shares a kubelet binary and
therefore moves together. Rolling one node at a time is still right, but the
roll is per Mac, not per node. A second Mac is a second checkout with its own
store, and is upgraded from that Mac.

**There is one etcd member and one API server.** The API is unreachable for the
few seconds between stopping the old control plane and the new one answering.
There is no version of this without an outage, and there cannot be until there
is more than one of each. Running pods are not touched by it.

## The version store

Everything Kubernetes-versioned lives under the version it belongs to:

```
bin/versions/v1.34.0/kubelet
bin/versions/v1.34.0/kube-apiserver          (built from v1.34.11 — see below)
bin/versions/v1.34.0/etcd
bin/versions/v1.34.0/MANIFEST
bin/kubelet -> versions/v1.34.0/kubelet
```

ferry's own binaries — `ferry-cri`, `ferry-cni`, the daemons — are not in the
store. They are the checkout's code rather than Kubernetes', and rolling the
cluster back to an older Kubernetes should not roll back the runtime with it.

The indirection is a symlink rather than a copy for two reasons. Rollback
becomes a flip rather than a rebuild. And nothing is ever written over a binary
that is running — which on macOS leaves that file permanently unrunnable, killed
at launch with a bare `Killed: 9` and a signature that still verifies. `ferry
doctor` has a check for exactly that failure; the store is built so it cannot
happen.

A checkout from before the store is adopted rather than rebuilt: `bin/kubelet`
and `bin/.kubelet-version` are a version directory with one binary in it, and
they are moved — `mv`, so the inode survives and a kubelet running right now
stays runnable.

### Two versions, not one

A cluster's version and a checkout's version are different facts and can
disagree.

- `bin/.active-version` — what this checkout has built, and what `bin/` points at.
- `$FERRY_HOME/version` — what the running cluster actually is.

A build moves the first and leaves the second alone. `ferry up` starts the
cluster at *its* recorded version, not at whatever was last built, so a build
cannot become an upgrade by accident; it says so when the two differ. `ferry
status` shows it.

### The control plane is pinned per minor

Upstream publishes no darwin build of the control plane, so `kube-apiserver` and
friends come from [kwok-ci/k8s](https://github.com/kwok-ci/k8s), which does not
build every patch release. The kubelet is compiled here from any tag that
exists; the control plane can only be a tag kwok-ci happens to have published.

So `lib/versions.sh` pins one control plane per minor. A v1.34.11 API server
with a v1.34.0 kubelet is the same minor, which is well inside the supported
skew. When a minor has no pin, ferry asks for the exact version and the download
says so if it does not exist:

```
K8S_CONTROL_PLANE_VERSION=v1.35.2 ferry upgrade apply v1.35.0
```

etcd is paired the same way, and `ETCD_VERSION` overrides it.

### What a fresh checkout builds

`FERRY_DEFAULT_K8S_VERSION` in `lib/versions.sh` is the version a checkout
builds when nothing says otherwise -- v1.37.0. It lives there, and not in each
script, because ferry, `build-kubelet.sh` and both control-plane scripts each
used to carry the literal separately; a default bumped in three of the four is
the split-version bug the store was built to end.

It only decides where a *new* checkout starts. ferry reads
`ferry_active_version` first, so a checkout that has built something stays on it
until asked to move, and raising the default cannot upgrade a running cluster
behind its back -- `ferry upgrade` still refuses to cross more than one minor at
a time, so a v1.34 cluster reaches v1.37 in three steps or not at all.

## Snapshots

Every switch that could touch the cluster's state takes an etcd snapshot first,
into `$FERRY_HOME/backups/`.

This is not belt and braces. Once an API server has started at a newer version
it may have written storage the older one cannot read, and at that point
flipping the binaries back is not a rollback — it is an API server that will not
start, over the only copy of the data. `tests/etcd-snapshot-test.sh` checks that
the snapshot ferry takes actually restores, with the flags ferry passes, into a
directory the etcd `control-plane/up.sh` starts will accept.

Where the etcd *minor* changes — v1.33 to v1.34 crosses 3.5 to 3.6 — the data
directory is migrated and etcd does not support going back down by swapping the
binary. `ferry upgrade plan` says so before you start. Rollback restores the
snapshot, which means losing anything written after the upgrade, and it says
that too.

## Rollback

```
ferry upgrade rollback
```

Goes back to the version before the last `apply`, which is recorded in
`$FERRY_HOME/version.previous`. It:

- refuses if the store no longer has that version, and says how to build it back;
- refuses if going back means going back an etcd minor and the snapshot is gone,
  because there is then no way back that keeps the data;
- snapshots the current state first, so the rollback is itself reversible;
- restores the pre-upgrade snapshot only when the etcd minor actually changed —
  a same-minor rollback keeps everything written since;
- tells you to roll the nodes back too, and to do it soon: after a control plane
  rollback the kubelets are *newer* than the API server, which is the one skew
  Kubernetes does not allow.

`apply` runs the same path by itself if the new control plane does not come up.

## Upgrading a node

```
ferry upgrade node ferry-mac
```

Drains with eviction, so PodDisruptionBudgets are honoured — upstream's
machinery, working here unchanged because the API server is upstream's. Pods
with no controller are not evicted without `--force`, which deletes them
outright; ferry says so rather than hanging, and uncordons the node again if the
drain fails.

Then it stops that node's kubelet — and only the kubelet — starts the new one on
the same config, waits for Ready, and uncordons.

`ferry upgrade nodes` does every node on this Mac in turn and stops at the first
one that does not come back, leaving the rest on their old kubelet, which is a
supported state. It then lists any node on another Mac that is still behind.

### Nodes on another Mac

There is no binary distribution: `ferry join` already says to copy the binaries
from the first Mac, and upgrades work the same way. Copy the new `bin/versions/`
across, then run `ferry upgrade node <name>` on that Mac.

A Mac that joined has only its kubelet's certificate, and a kubelet may not
evict another node's pods, so draining from there needs an admin kubeconfig:

```
FERRY_KUBECONFIG=/path/to/admin.conf ferry upgrade node <name>
```

## What is checked before anything happens

`ferry upgrade plan` and the first phase of `apply` run the same preflight,
cheapest check first — a release that does not exist should be found in a
second, not after twenty minutes of compiling a kubelet for it:

- the target is a version, and is not the one already running;
- the step is legal: one minor at a time, never backwards, never across a major;
- kwok-ci has a darwin/arm64 control plane for it;
- etcd publishes a darwin/arm64 build of its pair;
- kubernetes has the tag to build the kubelet from;
- there is disk for a source tree and a build;
- every node's current kubelet stays inside the skew against the new control plane.

`apply` then **builds everything before it touches anything**. A build that
fails costs time and not a cluster.

### The patches are the real risk

`patches/` is written against a particular tree, and nothing here can tell you
in advance whether it applies to a version it has never seen.
`build-kubelet.sh` asserts every textual seam it edits and fails loudly when one
has moved — so a drifted tree fails during the build, which happens before
anything is switched. `plan` warns when the target is a new minor for exactly
this reason. That is the honest position, not a claim that any minor works.

Shims whose signatures move between minors live in `patches/kubelet-vX.Y/`,
chosen by exact minor, and the build refuses before it clones if the minor being
built has no directory. v1.37 needs more than the two constructors the others
carry: cadvisor folded `info/v1` and `info/v2` into one `lib/model` package, and
an import path cannot be overridden from a second file, so that minor overlays
whole copies of `cadvisor_darwin.go` and `container_manager_darwin.go`.

### Rebuilding starts enforcing container CPU limits

Not a version upgrade, but it arrives with one, so it belongs here.

On darwin, package `cm` compiles upstream's `helpers_unsupported.go`, where
every CFS constant is `0` and both milli-CPU conversions return `0`. The kubelet
was therefore telling the runtime that every container wanted `CpuShares: 0,
CpuQuota: 0` — a CRI message that says no CPU limit at all, whatever the pod
spec said. `lib/overlay.sh` now redirects those conversions to `cm.Ferry*`,
which does upstream's real arithmetic.

**This does not change how big a pod's VM is.** That is decided once, at sandbox
creation, from the pod spec: CRI carries resources per container and never for
the pod, so `ferry-cri` asks `ferry-streamer` for the pod and sizes the machine
from the aggregate of its containers' limits. A pod asking for `cpu: 4` has
always got four vCPUs.

What changes is the cgroup *inside* that machine. With no quota in the CRI
config, `ferry-cri` left the container's `resources.cpu` unset, so every
container in a pod could use the whole VM whatever its own limit said — two
containers limited to `cpu: 2` each shared a 4-vCPU machine with neither bounded
to its half. After a rebuild each is held to its limit. A container that has
been quietly borrowing a sibling's headroom will stop, and if it was relying on
that to keep up, it will now be throttled at the number its spec actually asks
for. Containers with no CPU limit stay unbounded within their pod's machine,
which is what Kubernetes means by Burstable and BestEffort — a request is a
weight, not a ceiling, and is deliberately not turned into one here.

Limits are rounded **up** to whole CPUs, because a cgroup inside the guest is
the only lever and it takes whole CPUs. A container limited to `1500m` gets two
CPUs of quota rather than one; the VM is sized with the same rounding, so this
can never ask for more than the machine has. A limit below `1` CPU lands on one.

This is not gated by version: the bug was never version-specific, so a kubelet
rebuilt from this overlay at **any** version starts sending real limits. Roll it
out when you can watch it rather than alongside an unrelated upgrade.

## Tests

```
./tests/run.sh
```

- `tests/versions-test.sh` — the store and the skew rules: version arithmetic,
  what each version is paired with, installing and flipping and listing,
  adopting a pre-store checkout (including that the inode survives), and the
  cluster-version bookkeeping rollback depends on.
- `tests/upgrade-cli-test.sh` — the commands: dispatch, argument handling, and
  every refusal that happens before anything is touched, against a throwaway
  checkout with stub binaries and no cluster.
- `tests/etcd-snapshot-test.sh` — a real save and restore with the real etcd
  from the store, on ports of its own. Skipped until something has been built.
- `tests/overlay-test.sh` — the rewrites in `lib/overlay.sh`, against a fixture
  holding the lines upstream actually writes. It checks both that each rule
  fires and that `ferry_check_derived_darwin` notices when one stops firing, the
  second for every guard in the table rather than a chosen few. That matters
  most for the CFS conversions: a missed rewrite there still compiles, because
  `cm.MilliCPUToShares` exists on darwin, and simply goes back to sending zero.
  It covers the in-place rewrite too, which is how `kubelet_pods.go` -- the one
  file that reads those constants without carrying a build tag -- gets the same
  rules and the same assertion as the derived ones.

### What the tests do not cover, and what was run instead

The suites run without a cluster, so they cover the decisions and not the act.
The act was run by hand, on a real cluster, in both directions:

```
ferry build --kubernetes-version v1.34.0
ferry up
kubectl create deployment web --replicas=2 ...

ferry upgrade plan v1.34.11    # a supported step; node skew checked against the live API
ferry upgrade apply v1.34.11   # snapshot, stop, flip, restart, verify
kubectl get pods               # same pods, same names, same IPs, 0 restarts,
                               # ages carried straight through the switch
ferry upgrade nodes            # drain with eviction, kubelet replaced, Ready, uncordon

ferry upgrade rollback         # back to v1.34.0; same etcd minor, so nothing
                               # restored and nothing written since was lost
ferry upgrade nodes            # kubelets back to v1.34.0

ferry upgrade apply v1.34.11   # and forward again
ferry upgrade nodes
```

Also exercised: `ferry down`, a rebuild at the *other* version, and `ferry up`
— which started the cluster at its own recorded version and said so, rather
than letting the build become an upgrade.

The CPU change above was run the same way, on v1.36.4, against four builds — the
one before it, the kubelet half alone, the first attempt at the runtime half,
and what shipped — reading each container's `cpu.max` from inside its own VM and
then loading it past its limit to see whether the quota bit. Before, every
container read `max`: no limit at all, whatever its spec said. After, a 100m
container is throttled in every one of the fifty 100ms periods in five seconds
and delivers exactly the one CPU it is allowed, while a BestEffort container is
throttled in none and takes its whole machine. It also found that the kubelet
was logging two `not implemented` errors per pod per sync from a pod cgroup that
does not exist here. Reproducer and numbers in
[experiments/23-pod-cpu-limits](../experiments/23-pod-cpu-limits/FINDINGS.md).

Running it found three things the tests could not, all since fixed. The node
upgrade read the kubelet's version the moment the node went Ready, but a node
object keeps the old kubelet's status until the new one posts its own, so a node
that had upgraded correctly was reported as not having. The summary afterwards
listed local nodes under "nodes on other Macs", contradicting the line above it,
because it filtered by version rather than by which Mac runs them. And the
restart guard pointed at `ferry upgrade apply <older>`, which correctly refuses,
instead of at `rollback`.

**A minor bump has not been run.** Everything above is within v1.34, which
drives every path in this document except patch drift. A minor bump is a
different piece of work — porting `patches/` — and this machinery does not claim
to own it.
