# ferry against minikube

Every pod in ferry is a virtual machine with its own kernel. The obvious question
is what that costs, and the obvious guess is "start time". It does not cost start
time.

Measured on one machine (M-series, macOS 26.6.2) against minikube v1.38.1 on the
docker driver with Docker Desktop 29.2.1 -- the normal way to run minikube on a
Mac. Both had warm image caches. Readiness was measured from outside with
kubectl, not from what either tool prints about itself, so both are judged by the
same question: *is there a cluster that can run a workload* -- API serving, node
Ready, cluster DNS Ready.

## Control plane readiness

| | ferry | minikube |
|---|---|---|
| cold (no state at all) | **13.2s** | 67s |
| warm (restart) | **8.6s** | 14.9s |

ferry cold: 13.1, 13.2. minikube cold: 69.4, 64.6.
ferry warm: 7.5, 8.6, 9.5. minikube warm: 14.5, 14.9, 15.1.

The cold gap is architectural rather than clever. minikube has to create a node
-- a container holding a whole Linux distribution, kubelet and container runtime
-- before Kubernetes can begin. ferry has no node to create: the Mac is the node,
and the control plane is four native processes against etcd.

## Pod start, one at a time

Image already pulled; `kubectl run` to container Ready.

| | median | runs |
|---|---|---|
| ferry | **1.83s** | 1.98, 1.83, 1.85, 1.82, 1.83 |
| minikube | 1.88s | 1.94, 1.81, 1.88, 1.92, 1.86 |

The same, within noise. This is the result worth pausing on: booting a kernel and
a VM per pod costs nothing measurable against starting a container beside other
containers in a kernel that is already running.

It makes sense on inspection. Both numbers are dominated by the control plane --
scheduler, kubelet sync, status propagation -- not by whatever creates the
sandbox. A pod VM reaches userspace in about 0.12s
(see [03-vm-ceiling](../03-vm-ceiling/FINDINGS.md)); that is a rounding error
inside 1.8 seconds.

## Ten pods at once

| | | |
|---|---|---|
| ferry | **5.9s** | 5.9, 5.9 |
| minikube | 7.0s | 6.9, 7.0 |

Ten VMs with ten kernels, against ten containers sharing one. If VM-per-pod were
going to show up anywhere it would be here, and it does not.

## What a pod actually is

```
ferry     pod a kernel : 6.18.5-ferry   boot id 98ddfd35
          pod b kernel : 6.18.5-ferry   boot id 8026ecc4     <- different boots
          the host     : Darwin 25.6.0                       <- no Linux host

minikube  pod kernel   : 6.12.72-linuxkit
          node kernel  : 6.12.72-linuxkit                    <- the same kernel
```

That is the whole difference, and it is what the timings above are the price of.

## Idle footprint

| | |
|---|---|
| ferry, control plane + runtime + 3 pods | **0.63 GiB** resident |
| minikube node container | 606 MiB, inside a Docker VM sized at 15.55 GiB |

Not strictly comparable -- Docker Desktop's VM is provisioned up front and its
memory is not all resident -- which is itself the point: ferry has no VM to size.

## What is not measured here

- **One-time setup.** `ferry build` compiles a kubelet and a guest kernel and
  takes minutes. minikube's first run downloads a preload tarball. Neither is in
  the numbers above; both are paid once.
- Docker Desktop was running for minikube's numbers, because the docker driver
  requires it. ferry needs no Docker.
- Few trials on one machine. These are honest measurements, not a study.
