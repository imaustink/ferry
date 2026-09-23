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
ferry upgrade node <name>     just that one; --to vX.Y.Z for another version
ferry upgrade rollback        back to the version before the last apply
ferry upgrade prune           remove store versions nothing uses
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

**Each node runs its own version.** A node's kubelet is started out of its
version's directory in the store, not out of `bin/kubelet`, and the version is
recorded in `$FERRY_HOME/node-versions/<name>` -- in `FERRY_HOME` because the
run directory is under `/tmp` and a reboot is exactly what the record has to
outlive. `ferry up`, `ferry node add` under a name used before and the login
agent all start a node as what it last was, so a restart is never an upgrade.
Two nodes on one Mac have run v1.34.0 and v1.35.8 side by side. A second Mac is
a second checkout with its own store, and is upgraded from that Mac.

**`apply` touches no node.** It moves only the control plane's links in `bin/`.
It used to move every link, `bin/kubelet` included, so each node's next restart
-- a crash, a reboot -- would have been an unplanned upgrade without a drain.

**kube-proxy moves with the Mac.** `ferry-proxyd` is one per Mac however many
nodes it runs, so it follows the Mac's own node, index 0, and is restarted at
that node's version when `ferry upgrade node` moves it. Nothing upgraded it
before; it stayed on whatever the Mac first came up with.

**There is one etcd member and one API server, and the API is not
unreachable.** etcd is left running when the new version pairs with the same
one, and the API server's port is held across the switch, so a connection made
during it waits for about a second and a half rather than being refused. See
below for how, and what it measured.

## The version store

Everything Kubernetes-versioned lives under the version it belongs to:

```
bin/versions/v1.34.0/kubelet
bin/versions/v1.34.0/kube-apiserver          (built from v1.34.11 — see below)
bin/versions/v1.34.0/etcd
bin/versions/v1.34.0/MANIFEST
bin/kubelet -> versions/v1.34.0/kubelet
```

`bin/kubelet` is what `ferry build` last built, and what a node with no record
starts at when the cluster's own version has no kubelet in the store. Nothing
runs it by that name any more.

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

### What the store may lose

`ferry upgrade prune` lists the versions nothing references -- not the
cluster's, not rollback's, not what `bin/` points at, not any node's record on
this Mac, not ferry-proxyd's -- and not any a process is running from, whatever
the records say. `--yes` removes them.

## How the API server is replaced

Measured with the probe in
[experiments/28-control-plane-upgrades](../experiments/28-control-plane-upgrades/),
which asks every 50ms on a fresh connection and on a pooled one, and watches
the kubernetes Service's endpoint.

**It used to take twenty seconds, not a few.** The API server stops listening
at once on SIGTERM and then waits for its HTTP/2 streams to finish, and watches
never do, so it sat out its 60s request timeout -- measured, 60.2s -- until
down.sh killed it at ten. `--shutdown-watch-termination-grace-period=2s` has it
end them itself: 1.15s. That is also most of what `ferry down` was waiting on;
it takes 2.0s now.

After that, stop then start refused clients for 2.6–2.8s, and 1.6–2.2s with
etcd left running. etcd restarts only when MANIFEST's `etcd=` changes, which it
does not across v1.34 to v1.37.

**Two API servers cannot overlap on macOS**, although `--permit-port-sharing`
lets them share the port. macOS does not balance a shared port: every
connection goes to whichever listener bound first. And an API server's
post-start hooks call it back through a loopback client that dials
`[::1]:port` with a certificate it generated moments earlier -- beside the old
one, those calls reach the old one and fail verification, and the new one
exits. Both were measured, not assumed.

**So the port is held instead.** `ferry-handover` binds every IPv4 address the
Mac has on the API port. macOS always prefers a listener on a specific address
to a wildcard one, and an IPv4 socket binds beside the API server's dual-stack
`[::]` without either setting anything, being a different family. Every client
arrives over IPv4 -- kubeconfigs say 127.0.0.1, other Macs and pods through
10.96.0.1 arrive at the LAN address -- and the bridge splices each connection
through to `[::1]`, retrying while nothing is there. `[::1]` stays the API
server's own, which is what its loopback client needs. The old one is told to
stop, the new one starts the moment the old one has let go of the port, the
bridge holds what arrives until the new one's `/readyz` answers on `[::1]`, and
then lets go: new connections reach the API server directly, and each spliced
one is closed the first time it falls quiet.

Three handovers at the same version: 0 failed of 270–273 requests in each
series, and a connection made during the switch waited at most 1.48s. Watches
are ended cleanly by the old server and reopened. It does not need the old API
server to have been started with anything in particular, so the first upgrade
from a control plane started before this is handed over too.

**The kubernetes Service is written by ferry.** An API server's endpoint
reconciler takes its address out of the Service as it stops, and with one API
server at one address that emptied it -- 1.1–1.3s of refused connections to
10.96.0.1 after every restart, and one refused connection from a pod in the
first live upgrade. The API server runs with `--endpoint-reconciler-type=none`
and up.sh writes the Endpoints and EndpointSlice on every start.

Without `bin/ferry-handover` built, or when etcd has to restart, it is stop
then start, and `plan` says which.

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
binary. `ferry upgrade plan` says so before you start.

**A restore moves etcd's revision forward.** A snapshot's revision is older
than the one every watcher in the cluster last saw -- 1338 against 1682 on the
live rollback -- and a watch resumed from a revision etcd has not reached yet
simply waits for it, then carries on from there. Every kubelet, ferry-proxyd
and controller kept the world as it was before the restore: node objects
showed their restored status and pods showed Running that did not exist.
`etcd_restore` now passes `--bump-revision 1000000000 --mark-compacted`, which
is upstream's advice for restoring a cluster that has clients: every watch is
told its revision is gone and lists again, and the cluster converged in
seconds. This applied to the etcd-minor rollback as much as to anything new;
that path had never been run.

## Rollback

```
ferry upgrade rollback [--yes] [--keep-data]
```

Goes back to the version before the last `apply`, which is recorded in
`$FERRY_HOME/version.previous`. It:

- refuses if the store no longer has that version, and says how to build it back;
- refuses when that version is newer, since going there is an upgrade and has
  `apply`'s checks;
- **restores the pre-upgrade snapshot whenever the Kubernetes minor changes**,
  not only the etcd minor. An API server that has run at a newer minor may have
  written objects at storage versions the older one has never heard of -- an
  API that went GA and moved its storage version, a field the older one drops
  on its next write, a resource it does not serve -- and upstream does not
  support downgrading a control plane in place for that reason. The only state
  the older one is known to read is the one it left. It says when the snapshot
  was taken and what is lost -- every object created, changed or deleted since,
  and a pod whose object is gone is stopped by its kubelet -- and asks, unless
  `--yes`;
- keeps the data directory instead with `--keep-data`, across a Kubernetes
  minor only: across an etcd minor there is no such choice;
- refuses across a minor when the snapshot is gone, unless `--keep-data`;
- keeps everything written since within a minor, where a patch release does
  not change storage versions;
- snapshots the current state first, so the rollback is itself reversible;
- tells you to roll the nodes back too, and to do it soon: after a control plane
  rollback the kubelets are *newer* than the API server, which is the one skew
  Kubernetes does not allow. `ferry upgrade nodes` goes to the cluster's
  version, which is now the older one.

A restore stops etcd, so it is stop then start: 2.8s of refused connections on
the live rollback. `apply` runs the same path by itself if the new control
plane does not come up, unless the new API server never started at all -- then
the old one never stopped serving and nothing is put back.

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
the same config out of the new version's directory, records it, waits for
Ready, and uncordons. By default the new version is the cluster's own;
`--to vX.Y.Z` names another, which is built first if the store does not have
it, before anything is drained.

On the Mac's own node it then restarts ferry-proxyd at the same version, under
kube-proxy's skew rule, which is the kubelet's. Pods keep their last rules while
it is gone. A restarted ferry-proxyd used to sit on every Service change for
25 seconds, because ferry-cri asked it for rules newer than the generation the
old process had reached and the new one counted from zero; a Service created
just after took 28.5s to reach a pod, and takes 3.3s now that generations count
from the process's start.

The drain of the control plane Mac's own node leaves CoreDNS where it is. It
claims the address ferry reserves for cluster DNS, which belongs to that node's
pod subnet and no other, so evicted to another node it came up at another
address and cluster DNS was gone -- found by draining node 0 with a second node
beside it. The runtime keeps its VM across the kubelet swap.

`ferry upgrade nodes` does every node on this Mac in turn and stops at the first
one that does not come back, leaving the rest on their old kubelet, which is a
supported state. It then lists any node on another Mac that is still behind.

### Nodes on another Mac

There is no binary distribution: `ferry join` already says to copy the binaries
from the first Mac, and upgrades work the same way. Copy the new `bin/versions/`
across, then run `ferry upgrade node <name>` on that Mac. A Mac that joined does
not know the cluster's version, so there the default is what that checkout is
built at; `--to` names the one to go to.

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
- **every node in the cluster**, read from the API's `nodeInfo.kubeletVersion`,
  stays inside the skew against the new control plane -- and if one would not,
  `apply` refuses, where it used to check only this Mac's nodes, only in
  `plan`, and only warn. A kubelet three minors behind on another Mac would
  otherwise have been cut off from the API server by an upgrade that reported
  success;
- this Mac's ferry-proxyd stays inside kube-proxy's skew, the same rule;
- nothing is still asking for an API the target removes, from the API server's
  `apiserver_requested_deprecated_apis` gauge. The objects themselves are safe
  -- the API server converts them -- but the clients asking get 404s, so
  `apply` refuses unless `FERRY_ALLOW_REMOVED_APIS=1`. The gauge only covers
  requests since the API server started, so an empty answer means nothing
  asked lately.

`apply` then **builds everything before it touches anything**. A build that
fails costs time and not a cluster.

### The patches are the real risk

`patches/` is written against a particular tree, and nothing here can tell you
in advance whether it applies to a version it has never seen.
`build-kubelet.sh` asserts every textual seam it edits and fails loudly when one
has moved — so a drifted tree fails during the build, which happens before
anything is switched. `plan` warns when the target is a new minor for exactly
this reason. That is the honest position, not a claim that any minor works.

Every seam fails the build when the file it edits is not where it was. They
used to be skipped quietly, each behind an `if [ -f ]`, which would have turned
a moved file into a kubelet built without that edit. Making them loud found two
that had never applied: `file_linux.go`'s tag was widened to darwin, which a
`_linux.go` name makes impossible, and `file_unsupported.go` was narrowed away
from darwin by a pattern its `!linux` tag did not match. The two cancelled out.
Both are gone; ferry sets no `staticPodPath`, so nothing depended on them.

Shims whose signatures move between minors live in `patches/kubelet-vX.Y/`,
chosen by exact minor, and the build refuses before it clones if the minor being
built has no directory. Each records, in `SIGNATURES`, the upstream signatures
of the three constructors its shims stand in for -- `cadvisor.New`,
`cm.NewContainerManager` and `nftables.NewProxier` -- and the build compares
them with the tree before applying anything. A moved constructor fails in a
second, old and new side by side, rather than as "not enough arguments" several
minutes in. Once the shim is ported, `FERRY_RECORD_SIGNATURES=1` records the
new ones. v1.37 needs more than the two constructors the others
carry: cadvisor folded `info/v1` and `info/v2` into one `lib/model` package, and
an import path cannot be overridden from a second file, so that minor overlays
whole copies of `cadvisor_darwin.go` and `container_manager_darwin.go`.

`ferry-proxyd` is shimmed the same way. `nftables.NewProxier` took every knob
positionally through v1.36 and takes a `KubeProxyConfiguration` from v1.37, so
the call lives in `patches/kubelet-vX.Y/cmd/ferry-proxyd/ferry_new_proxier.go`
and `main.go` only calls `ferryNewProxier`. The values passed are the same on
both sides of that change; a minor added without its shim fails to compile on
the one function rather than anywhere else.

v1.37 is also the first minor to vendor knftables v0.0.22, which added
`netlink.go` with no build tag. That file reaches the kernel through
`github.com/google/nftables`, whose `xt` package reads `unix.NFPROTO_*` --
constants darwin does not declare -- so the whole package stopped compiling and
took `ferry-proxyd`, and therefore Services, with it. `build-kubelet.sh` narrows
the file to linux and the v1.37 overlay supplies a darwin stand-in for the two
names `nftables.go` still refers to. Nothing is lost: `newNetlinkAdapter` is
only reached behind the `UseNetlink` opt-in, which the proxier never sets.

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
- `tests/upgrade-lib-test.sh` — `lib/upgrade.sh`: which version a node and
  ferry-proxyd start at, and that a record whose kubelet has gone says so; when
  a rollback restores; which APIs a target removes, from a fixture of the
  gauge's real lines; what `prune` may take.
- `tests/build-seams-test.sh` — signature extraction and comparison, that every
  `patches/kubelet-vX.Y/` records all three constructors and matches a cached
  tree of its minor when there is one, and that no seam in `build-kubelet.sh`
  is behind an `if [ -f ]` again.
- `tests/control-plane-minor-test.sh` — a control plane walked v1.34 → v1.35 →
  v1.36 → v1.37 with up.sh and the environment `apply` passes, on ports and a
  directory of its own, under the probe: each step answers at the new minor with
  no failed request (0/71, 0/73, 0/81), the objects written at v1.34 -- a CRD and
  its object, a Deployment, a Secret, a PDB, a Lease -- are the same UIDs with
  the same data, and nothing fails to decode. Then v1.37 goes back to v1.36 by
  snapshot at a bumped revision, losing only what v1.37 wrote. 29 assertions in
  about 30 seconds; skipped until the store has a control plane for each minor.

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

### A minor bump, on a running cluster

Run on a two-node cluster -- the Mac's own node and one from `ferry node add` --
carrying a Deployment behind a Service with a PodDisruptionBudget, a Secret, a
CRD and its object, a Lease, and a client pod reaching the Service and
10.96.0.1 every 200ms, under the probe:

```
ferry upgrade apply v1.35.8        # from v1.34.0: 0 of 2969 /readyz failed; every
                                   # UID, pod name, IP, restart count and start
                                   # time unchanged; 0 decode errors; bin/kubelet
                                   # still v1.34.0
ferry upgrade node n2              # alone: v1.34.0 and v1.35.8 on one Mac
ferry upgrade nodes --force        # the PDB held the second eviction until the
                                   # first replacement was ready; ferry-proxyd
                                   # moved with the Mac's node
ferry upgrade rollback --yes       # restored the snapshot; what was written
                                   # after it was gone, as warned
ferry upgrade nodes --force        # back to v1.34.0
ferry upgrade apply v1.35.8        # 0 of 1472 failed in every series, and the
                                   # client pod logged nothing across it
ferry upgrade nodes --force
ferry upgrade apply v1.36.4        # by handover again, clean
ferry upgrade nodes --force
ferry down && ferry up             # node 0 on v1.35.8, cluster v1.36.4: node 0
ferry node add n2                  # came back on v1.35.8 and n2 on v1.36.4
```

It found five things, all fixed above: an API server that took a minute to stop;
the kubernetes Service emptied by every API server leaving; CoreDNS evicted
off the node whose address it holds; a restored etcd whose revision went back,
so no watcher saw the restore; and ferry-proxyd sitting on Service changes for
25 seconds after a restart. The `--force` was for `ferry-builder`, a pod with no
controller, which drain declines to delete without being told.

What has not been run is a node on a *second* Mac through a minor, and a minor
whose etcd pairing changes, which is stop-then-start by design.
