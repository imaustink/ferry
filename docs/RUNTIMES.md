# Choosing where a pod runs

A ferry cluster can run a pod two ways, and a pod picks one with
`runtimeClassName`, the same field Kata Containers and gVisor users already
know:

| `runtimeClassName` | the pod is | it runs on | worth it for |
|---|---|---|---|
| `ferry-vm` | a virtual machine of its own, with its own kernel | the Mac | isolation: untrusted or privileged code, anything that wants its own kernel |
| `ferry-shared` | a container sharing a machine's kernel | a machine (mode 2) | density and start time: many small services |

A pod VM costs the Mac about 133 MiB before its workload does anything; a
container on a machine costs about 14 MiB. Why the two exist, and what each
costs, is in [MACHINES.md](MACHINES.md). This page is how to use them.

Both rows above run **Linux** pods. A cluster with a macOS golden image can also
run **native macOS** pods — Darwin processes for `xcodebuild`, the iOS
simulator, `codesign` or any macOS-only tool — with two more classes in the
same two modes. See [macOS pods](#macos-pods).

`ferry-shared` needs machines turned on: `ferry machines enable`, or
`machines: true` in [ferry's config](INSTALL.md#configuration). `ferry-vm`
always works.

## Asking for a runtime

On a Pod, it is a field of the spec:

```yaml
apiVersion: v1
kind: Pod
metadata: {name: api}
spec:
  runtimeClassName: ferry-shared
  containers:
    - {name: api, image: myorg/api:1.2}
```

On anything that makes pods, such as a Deployment, StatefulSet, DaemonSet, Job or
CronJob, it goes in the **pod template**, not at the top of the object:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: {name: web}
spec:
  replicas: 5
  selector: {matchLabels: {app: web}}
  template:
    metadata: {labels: {app: web}}
    spec:
      runtimeClassName: ferry-shared      # here
      containers:
        - {name: web, image: nginx:1.27}
```

```yaml
apiVersion: batch/v1
kind: Job
metadata: {name: migrate}
spec:
  template:
    spec:
      runtimeClassName: ferry-vm          # its own kernel for a one-off privileged task
      restartPolicy: Never
      containers:
        - name: migrate
          image: myorg/migrate:1.2
          securityContext: {privileged: true}
```

A stack usually mixes them. The pieces that should not share a kernel with
anything, such as a build step or a sandbox for user code, say `ferry-vm`. The many
small services say `ferry-shared`, or say nothing and take the cluster's
default.

## What happens when you apply it

Kubernetes merges the class's scheduling rules into the pod as it is created,
so `kubectl get pod <name> -o yaml` shows them:

- a `nodeSelector` of `ferry.dev/mode: vm-per-pod` or `shared`, which is the
  label on the Mac and on each machine, as `kubectl get nodes -L ferry.dev/mode` shows;
- a toleration for that kind of node's taint, which matters when the cluster
  has a default (below);
- for `ferry-vm`, `overhead: {memory: 133Mi}`, which the scheduler counts
  against the Mac's memory on top of the pod's own requests. That is what a pod
  VM costs whatever runs in it, and counting it stops the scheduler from
  promising the Mac pods it cannot hold.

Then:

- **`ferry-vm`** is scheduled onto the Mac.
- **`ferry-shared`** goes to a machine with room for it. If none has room,
  ferry's provisioner (Karpenter) makes a machine shaped to fit, which takes about fifteen
  seconds to reach Ready, and removes it about a minute after it is empty.
  You do not size or declare machines for this; the pod's requests are the
  size.

## Pods that do not name one

Most manifests you did not write, such as Helm charts, addons and examples, do not
name a RuntimeClass. Where those pods go is the cluster's `defaultRuntime`:

| `defaultRuntime` | a pod that names no RuntimeClass |
|---|---|
| `none` | goes wherever it fits. With machines on, that can split one Deployment across the Mac and a machine |
| `ferry-vm` | runs on the Mac |
| `ferry-shared` | runs on a machine while machines are on, otherwise on the Mac |

`none` is what a cluster has until someone chooses; `ferry init` asks.

```sh
ferry config get defaultRuntime
ferry config set defaultRuntime ferry-shared     # applies to the running cluster at once
```

So pick the default that fits most of your workloads, and name the class only
on the exceptions. With `defaultRuntime: ferry-shared`, everything is dense by
default and the pods that need isolation say `ferry-vm`. With `ferry-vm`, it is the
reverse.

Two things to know about changing it:

- **Running pods stay where they are.** The default decides where new pods go.
  To move a workload, restart it: `kubectl rollout restart deploy/<name>`.
- **Provisioned machines are replaced** when the default changes to or from
  `ferry-vm`, because the machines Karpenter makes carry the default's taint.
  Karpenter moves their pods as it would for any consolidation.

### DaemonSets meant for every node

A default is a `NoSchedule` taint on the other kind of node. The DaemonSet
controller only tolerates the taints Kubernetes itself puts on nodes, such as
not-ready, unreachable and disk pressure, and not `ferry.dev/mode`. So
once a default is set, a DaemonSet meant to run everywhere, such as a logging or
monitoring agent or node-exporter, **silently skips the tainted kind**. Nothing
fails. Its `DESIRED` count is smaller than the number of nodes.

`runtimeClassName` is not the fix here, because it pins a pod to one kind of
node. Tolerate the taint whatever its value instead:

```yaml
spec:
  template:
    spec:
      tolerations:
        - {key: ferry.dev/mode, operator: Exists, effect: NoSchedule}
```

That is how ferry's own kube-proxy for machines is written. Before adding it,
consider whether the agent should run on the Mac at all: a DaemonSet pod on the
Mac is a pod VM of its own, and an agent that reads its node's kernel, files or
network namespace would be reading that VM, not the Mac. Agents like that
usually belong only on machines, which is `runtimeClassName: ferry-shared` again.

Kubernetes has no default RuntimeClass, so ferry makes a default by tainting
the other kind of node. The details are in
[MACHINES.md](MACHINES.md#a-default-for-pods-that-do-not-choose).

## The older spelling: `nodeSelector`

Before the classes existed a pod picked with the node label directly, and it
still can:

```yaml
nodeSelector: {ferry.dev/mode: shared}      # like ferry-shared
nodeSelector: {ferry.dev/mode: vm-per-pod}  # like ferry-vm
```

**It stops working for the non-default kind once a default is set.** The
default taints the other kind of node, and a bare `nodeSelector` carries no
toleration for it: under `defaultRuntime: ferry-vm`, a pod with
`nodeSelector: {ferry.dev/mode: shared}` stays Pending, and Karpenter will not
make a machine for it either. `runtimeClassName` carries the toleration, so
prefer it.

## One particular machine

The runtime picks the kind of node. To pick a node, add an ordinary selector
beside it. For example, a pod that should run on a Machine you declared with
a stronger disk guarantee:

```yaml
apiVersion: ferry.dev/v1alpha1
kind: Machine
metadata: {name: db-0}
spec: {cpus: 2, memory: 4Gi, durability: power-loss}
---
apiVersion: v1
kind: Pod
metadata: {name: db}
spec:
  runtimeClassName: ferry-shared
  nodeSelector: {kubernetes.io/hostname: db-0}
  containers:
    - {name: db, image: postgres:17}
```

`durability` on a Machine is what its disk survives.
[INSTALL.md](INSTALL.md#configuration) has the levels.

## macOS pods

Everything above runs Linux pods. A cluster whose Mac has a macOS golden image
can also run **native macOS** pods — Darwin processes for `xcodebuild`, the iOS
simulator, `codesign` or any macOS-only tool. They pick a runtime the same way,
with two more classes for the same two modes:

| `runtimeClassName` | the pod is | worth it for |
|---|---|---|
| `ferry-macos-vm` | a macOS VM of its own, with its own XNU kernel | a job that must be root, load a kext, or change system settings |
| `ferry-macos-shared` | a macOS process on a machine's kernel (a uid + a chroot) | density: many macOS pods past the two-guest ceiling — **off by default, trusted code only** (see the warning below) |

Both use the handler `ferry-darwin` and a darwin image. As with the Linux
classes, the class carries the `nodeSelector` and toleration, so
`runtimeClassName` is all you write on the pod:

```yaml
apiVersion: v1
kind: Pod
metadata: {name: build}
spec:
  runtimeClassName: ferry-macos-vm        # or ferry-macos-shared
  restartPolicy: Never
  containers:
    - {name: build, image: myorg/build-darwin:1}
```

On a Deployment, Job or any object that makes pods it goes in the pod template,
exactly as `ferry-shared` does above.

> ⚠️ **`ferry-macos-shared` is not a security boundary — run only code you
> trust on it.** Darwin has no namespaces and no cgroups, so a shared-kernel
> macOS pod is not a container in the Linux sense. It is a per-pod uid, a
> `chroot` for a private `/`, a Seatbelt profile and pf rules — assembled on a
> guest that must run with **SIP disabled**, i.e. with the kernel's own
> protections turned off. The `chroot` hides the filesystem and nothing else,
> and it holds only because the pod is not root; there is no VM between one pod
> and the next, and no hardened kernel beneath them. A pod that reaches root, or
> a kernel bug, is not contained the way a VM contains it. Its limits are soft,
> too: memory and CPU are enforced by polling (a poll-and-kill OOM watcher, a
> `SIGSTOP`/`SIGCONT` duty cycle), not a hard barrier, so a brief burst can
> overshoot before it is caught.
>
> For anything untrusted, privileged, or hostile — CI running third-party pull
> requests, a sandbox for user code, anything you would not run as yourself on
> your own Mac — use **`ferry-macos-vm`** instead, where each pod is its own
> single-use XNU kernel behind a hypervisor. That is the same isolation
> `ferry-vm` gives a Linux pod; `ferry-macos-shared` is closer to running the
> workload as another user on one machine.
>
> **It is off by default.** `ferry-macos-vm` needs only a macOS image
> (`FERRY_MAC_IMAGE`); `ferry-macos-shared` also needs **`FERRY_MAC_SHARED=1`**.
> Without it ferry installs no shared NodePool and `ferry-machined` refuses a
> hand-declared `spec.os: darwin` machine that is not `spec.isolation: vm`, so a
> `ferry-macos-shared` pod stays Pending — you have to opt in, knowing the above.

Three things set macOS pods apart from the Linux classes:

- **They need a macOS image.** Both run on macOS machines — `Machine`s with
  `spec.os: darwin` — which ferry only provisions when this Mac has a golden
  macOS image (the `FERRY_MAC_IMAGE` bundle, passed to ferry-machined as
  `--mac-image`). Without one the classes still exist but nothing schedules onto
  them, and a pod that names one stays Pending. Building it is
  [below](#building-the-image).
- **A macOS machine is always tainted.** Under every `defaultRuntime` a macOS
  machine carries its `ferry.dev/mode` taint, so `runtimeClassName` — which
  brings the matching toleration — is the *only* way onto one. A bare
  `nodeSelector: {ferry.dev/mode: shared-macos}` stays Pending, and a pod that
  names no class never lands on XNU.
- **The Mac runs two macOS guests at most, of either kind.** A `ferry-macos-vm`
  pod takes a whole guest to itself — its machine is registered with
  `maxPods: 1` and is torn down when the pod finishes, so the next pod gets a
  fresh one, never a used kernel. `ferry-macos-shared` pods pack many onto a
  guest. Either way the two-guest ceiling is shared: a third `ferry-macos-vm`
  pod, or the first shared pod while two VM pods hold both slots, waits Pending
  until a slot frees. Getting past two is exactly what `ferry-macos-shared`
  buys.

So the choice mirrors `ferry-vm` vs `ferry-shared`, but the gap is wider: with
no namespaces or cgroups to build on, `ferry-macos-shared` is a uid and a chroot
on a shared kernel — cheaper and denser, and **not a boundary against the host
kernel or the other pods on it**. `ferry-macos-vm` is a hypervisor boundary
between pods (root, its own kernel, single-use), and the only one of the two you
should hand code you do not trust.

### Building the image

macOS pods need two things built. The **golden macOS bundle** the machine
boots is `ferry mac-image bake`, below. The **pod image** is `ferry image
build --os darwin` (below that).

**1. The golden macOS bundle** — the OS a macOS machine boots, and what
`FERRY_MAC_IMAGE` points at. Built with one command, from a checkout (like
`ferry kernel` and `ferry node-image`, it needs tools a release does not
carry, so it is not something an installed ferry can do):

```sh
./ferry mac-image bake
```

This downloads macOS straight from Apple's own restore-image catalog onto
*this* Mac and assembles the bundle here — nothing Apple-owned is ever
carried by ferry itself, only the tooling that does the assembling. Apple's
license for macOS does not permit redistributing copies of it (including as a
baked VM bundle), which is also why the result is a checkout-only artifact:
there is nothing a release could ship here that would help the next Mac, the
same reasoning behind `ferry kernel` and `ferry node-image`.

It prints the resulting `export FERRY_MAC_IMAGE=...` line and reminds you to
run `ferry machines enable`. `--rebuild` redoes every step even if this Mac
already has one cached; `--ipsw <path>` uses a restore image already on disk
instead of asking Apple for the latest one; `--out <dir>` picks where it is
written (default `$FERRY_HOME/mac-image`).

By default this prepares an image for **`ferry-macos-vm`** only, which needs
no manual steps beyond the one `sudo` prompt (putting the guest agent on the
bundle). For **`ferry-macos-shared`** as well, add `--shared`:

```sh
./ferry mac-image bake --shared
```

`--shared` does one thing the plain form does not: it clones the bundle and
turns **SIP off** in the clone, because the per-pod `chroot` needs it — a
recoveryOS step that cannot be scripted, so `ferry mac-image bake` opens the
recovery window and waits for you to finish it (make an admin, `diskutil apfs
updatePreboot /`, `csrutil disable`, `halt`) before it bakes the final image.
This is also why a shared-macos node is not a security boundary
([above](#macos-pods)): its kernel runs with SIP disabled. The image is still
just built, though — turning the class on is the separate opt-in below.

Point ferry at the baked bundle and bring machines up (`ferry mac-image bake`
prints the exact lines for what it built):

```sh
export FERRY_MAC_IMAGE="$HOME/.ferry/mac-image/golden-node"
export FERRY_MAC_SHARED=1   # only if baked with --shared and you want ferry-macos-shared; omit for VM-per-pod only
ferry up                # installs the macOS NodePool(s), passes --mac-image to ferry-machined
ferry machines enable
```

`FERRY_MAC_SHARED=1` is what turns on the shared-kernel pool and lets
`ferry-machined` register a shared macOS machine — leave it out and only
`ferry-macos-vm` works, which is the safe default (see the warning above).

<details>
<summary>What <code>ferry mac-image bake</code> runs, if you want to drive it by hand</summary>

```sh
cd experiments/39-macos-pods
./build.sh                                          # macvm, ferry-macagent, latest-ipsw
./build/latest-ipsw                                 # prints the URL Apple serves for this Mac
curl -fLo .cache/mac.ipsw <that URL>
build/macvm install .cache/mac.ipsw .cache/golden   # ~3 min: installs macOS into a bundle
sudo ./inject.sh .cache/golden                      # put the guest agent on it (root, once)
```

That much already boots a macOS VM. For `ferry-macos-shared`, additionally:

```sh
cp -Rc .cache/golden .cache/golden-sipoff           # APFS clone, instant
build/macvm boot .cache/golden-sipoff --recovery    # opens the recovery window
# in the guest: make an admin, run `diskutil apfs updatePreboot /`,
#               then `csrutil disable` and `halt`
```

Then bake the machine image from either bundle — kubelet, `ferry-darwin` and
the OS base copied in, so a machine is Ready in ~10 s instead of spending
~30 s on first boot:

```sh
./bake-macos-node.sh .cache/golden .cache/golden-node             # ferry-macos-vm only
./bake-macos-node.sh .cache/golden-sipoff .cache/golden-node      # with --shared
```

</details>

**2. A darwin pod image** — what a macOS pod runs. It holds only *your own*
arm64/arm64e binaries: dyld and the system libraries come from the node, because
Apple's signed binaries are killed anywhere but where the OS put them. So it is
`FROM scratch` plus `COPY` — the node is the base, not a layer, and there is no
`RUN` (a Linux builder cannot execute Darwin binaries; compile on the Mac and
copy the result in). `ferry image build --os darwin` packages it:

```sh
cat > Dockerfile <<'EOF'
FROM scratch
COPY app /bin/app                # your own arm64/arm64e binary
ENTRYPOINT ["/bin/app"]
EOF
ferry image build --os darwin -t example.com/app-darwin:1 .
```

Unlike a Linux build this needs no buildkit; it writes the OCI layout directly
and serves it from this Mac's registry, so **machines must be on**
(`ferry machines enable`) — a macOS pod always runs on a machine, and that is
where it pulls from. A pod that names `image: example.com/app-darwin:1` with
`runtimeClassName: ferry-macos-shared` (or `ferry-macos-vm`) and
`imagePullPolicy: IfNotPresent` then runs it.

`ferry image build --os darwin` accepts the common Dockerfile instructions that
don't run anything — `COPY`/`ADD`, `ENTRYPOINT`, `CMD`, `ENV`, `WORKDIR`,
`LABEL` — and rejects `RUN` (and `--build-arg`) with a message saying why. The
full walk-through of the macOS runtime is
[experiment 39's FINDINGS](../experiments/39-macos-pods/FINDINGS.md).

## Checking where things landed

```sh
kubectl get nodes -L ferry.dev/mode                        # which node is which kind
kubectl get pods -o wide                                   # which node each pod is on
kubectl get pod <name> -o jsonpath='{.spec.runtimeClassName}{"\n"}'
kubectl get machines                                       # machines, provisioned ones included
ferry status                                               # the default runtime in effect
```

## When a pod will not start

`kubectl describe pod <name>` says why, in its Events.

| what it says | why | what to do |
|---|---|---|
| `untolerated taint {ferry.dev/mode: …}` | the pod picks a node kind by `nodeSelector`, and the cluster's default has tainted that kind | use `runtimeClassName` instead |
| `didn't match Pod's node affinity/selector`, for a `ferry-shared` pod | no machines: mode 2 is off | `ferry machines enable` |
| a DaemonSet's `DESIRED` is fewer than your nodes, with no error | the cluster's default has tainted one kind of node, and the DaemonSet does not tolerate it | add the toleration under [DaemonSets meant for every node](#daemonsets-meant-for-every-node) |
| `RuntimeClass "…" not found` | the class does not exist in this cluster, usually one started by a ferry older than the classes | `ferry up` installs them; so do `ferry image build` and `ferry addons enable` |
| a `ferry-macos-*` pod stays Pending and no machine appears | this Mac has no macOS golden image, so no `spec.os: darwin` machine can be made for it | `ferry mac-image bake`, then `export FERRY_MAC_IMAGE=...` as it prints and `ferry machines enable` |
| `Failed to create pod sandbox: … has no runtime handler "runc"` | a pod whose class is not `ferry-vm` was put on the Mac anyway, usually with `nodeName` | let the scheduler place it, or name `ferry-vm` |

The last one is deliberate. ferry-cri runs every pod as a VM, and a pod that
asked for something else is refused rather than quietly made into a VM.

## Things that do not work

- **Changing a running pod's runtime.** Kubernetes does not allow it on a pod.
  Change the pod template and let the workload roll out new pods.
- **`ferry-shared` without machines.** The pod waits in Pending until
  `ferry machines enable`.
- **A default of `ferry-shared` with machines off.** It is kept in the config
  file but not applied, because tainting the Mac with nowhere else to go would leave
  no node that runs a pod. `ferry config` says `ferry-shared waits for
  machines` until they are on.
