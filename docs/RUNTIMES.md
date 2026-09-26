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
