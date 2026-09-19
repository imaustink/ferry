# Experiment 19 — A node made by applying a resource

**Question.** Milestone 2 of [docs/MACHINES.md](../../docs/MACHINES.md): can a
node be created by writing a `Machine` object and removed by deleting it, with
a controller doing everything in between?

**Method.** `ferry-machined`, a Go process next to the control plane, watches
`machines.ferry.dev` and calls `ferry-node` — the Swift tool from
[experiment 18](../18-node-image/FINDINGS.md) — to clone a disk and boot a
machine. The split is ferry's existing one: Go talks to the API server, Swift
talks to `Virtualization.framework`, exactly as `ferry-streamer` and `ferry-cri`
already divide the work.

Run on macOS 26.6.2, Apple M1 Max, 10 cores, 32 GiB.

## Results

```
$ kubectl apply -f machine.yaml
NAME       PHASE   ADDRESS   NODE   AGE
worker-0                            0s

APPLY_TO_READY_SECONDS=16.0
NAME       PHASE     ADDRESS        NODE       AGE
worker-0   Running   192.168.82.2   worker-0   19s

NAME       STATUS   ROLES    AGE   VERSION
worker-0   Ready    <none>   4s    v1.34.11

$ kubectl delete machine worker-0
DELETE_TO_GONE_SECONDS=3.0
machines left: 0   nodes named worker-0: 0
VM_STOPPED
```

**16 seconds from `kubectl apply` to a Ready node**, against 13.1s for the same
machine booted by hand — the difference is the controller's poll interval and
the token it has to create first. **3 seconds to delete**, which matters more
than it looks: deleting a VM is the only thing that returns memory to the host
([experiment 14](../14-balloon/FINDINGS.md)), so consolidation's cost is three
seconds and a boot.

`kubectl get machines` reports what is true rather than what was asked for. The
address appears once the machine has one, and `NODE` fills in only when the
kubelet has actually registered — a machine that boots and never joins says so
by leaving that column empty.

### What the controller does per machine

1. Adds a finalizer, so the object outlives `kubectl delete` until the VM is
   really gone. Without it the resource disappears and the machine keeps
   running with nothing pointing at it.
2. Creates a bootstrap token Secret of its own, and the RBAC that lets a
   joining kubelet ask for a certificate and have it approved.
3. Clones the node disk with `cp -c`, which on APFS is instant and costs
   nothing until the node writes to it.
4. Runs `ferry-node run` as a child process and reads back the address it
   allocated from a status file — rather than parsing it out of a log line,
   which is the kind of coupling that breaks quietly.
5. Reports `phase`, `address` and `nodeRef` as they become true.

On delete it stops the VM, deletes the `Node` object — otherwise the scheduler
keeps placing pods on a machine that no longer exists — removes the token and
the disk, and only then drops the finalizer.

### Two machines at once, and an edit that is refused

`./two-machines.sh`:

```
  PASS  both machines reach Ready
  NAME       PHASE     ADDRESS        NODE       AGE
  worker-a   Running   192.168.83.2   worker-a   14s
  worker-b   Running   192.168.84.2   worker-b   14s
  PASS  each machine has its own address
  PASS  each machine has its own bootstrap token
  PASS  each machine has its own disk
  PASS  editing spec is rejected
        The Machine "worker-a" is invalid: spec: Invalid value: "object": a machine's
        spec is immutable, because a running VM cannot be resized; delete this
        machine and create one of the size you want
  PASS  worker-a node is gone
  PASS  worker-b is still Ready
```

The edit is refused by the API server rather than by the controller, through a
CEL rule on the CRD. A controller that quietly ignored the edit would leave
`kubectl get machine` describing a machine that does not exist; refusing it says
the true thing, which is that a running VM cannot be resized
([experiment 14](../14-balloon/FINDINGS.md)).

### One vmnet network per machine, and that is a problem for milestone 3

Look at the two addresses above: `192.168.83.2` and `192.168.84.2`. Each
`ferry-node` process creates its own vmnet network, and vmnet keeps its networks
apart -- so those two nodes cannot reach each other, and pods on them certainly
cannot. There are also only 32 networks for the whole Mac
([experiment 07](../07-vmnet-leak/FINDINGS.md)), which caps machines long before
memory does.

Asking both machines for the *same* subnet settles what milestone 3 can do:

```
shared-a   booted, gateway 192.168.211.1
shared-b   failed to create vmnet network with status 1001
```

**Two processes cannot share one vmnet network.** So milestone 3 cannot be "put
every node on one network" while each machine is its own process. The shape that
works is the one `ferry-cri` already uses: one process holding one vmnet network
and hosting every VM on it. `ferry-node` would become a long-lived server that
`ferry-machined` asks for machines, rather than a process per machine.

That is a real design answer, and it is better to have it now than after
building the routing that assumes otherwise.

## What this means

- **Milestone 2 is met.** A node is now a declared thing, and the shape the
  provisioner needs is in place: something else can create `Machine` objects
  and this will make them real.
- **The next milestone is the interesting one.** Milestone 4 is the provisioner
  deciding *which* machines should exist from pending pods, and milestone 5 is
  consolidation deleting them again. Both are now just writing and deleting
  these objects.

## Caveats

- **A poll, not an informer.** The loop lists machines every two seconds, which
  is simpler to read and costs a second of latency. With a handful of machines
  on one Mac that is the right trade; with hundreds it would not be.
- **`spec.image` is a path**, not a registry reference. A real Machine should
  name an image the way a pod does.
- **No `MachineSet`, no replicas, no rolling replacement.** Editing `spec` is
  now refused, which is the honest behaviour, but nothing replaces a machine for
  you.
- **Two machines is as far as this goes.** They are independent and correct,
  but on separate networks, so nothing pod-to-pod between nodes works yet.
- **The control plane is a throwaway** on shifted ports, and the addons are
  applied by the runner rather than by ferry.

## Reproduce

```sh
../18-node-image/build.sh           # the node image and ferry-node
( cd ../../ferry-machined && go build -o ../bin/ferry-machined . )
./run.sh                            # apply, Ready, delete, gone
./two-machines.sh                   # two at once, and an edit that is refused
KEEP=1 ./run.sh                     # and leave it up to poke at
```
