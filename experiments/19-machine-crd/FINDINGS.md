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
- **No `MachineSet`, no replicas, no rolling replacement.** Changing `spec` on
  an existing machine does nothing — the resources are immutable by design, so
  the controller ought to reject the edit rather than ignore it.
- **One Mac, one node tested at a time.** Nothing here has been run with
  several machines at once, and cross-node pod networking is still milestone 3.
- **The control plane is a throwaway** on shifted ports, and the addons are
  applied by the runner rather than by ferry.

## Reproduce

```sh
../18-node-image/build.sh           # the node image and ferry-node
( cd ../../ferry-machined && go build -o ../bin/ferry-machined . )
./run.sh                            # apply, Ready, delete, gone
KEEP=1 ./run.sh                     # and leave it up to poke at
```
