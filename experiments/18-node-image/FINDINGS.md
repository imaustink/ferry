# Experiment 18: the node image

**Question.** [Experiment 17](../17-node-vm/FINDINGS.md) proved a Linux node can
join ferry's control plane, by staging a node's software into a `ferry-cri` pod
VM. Four things stopped it along the way, and none were about virtualization.
They were the difference between an image built to be a container and one built
to be a node. This builds the second kind.

**Method.** Docker builds the image, because that is the tooling everyone has.
`ferry-node build` unpacks it into an ext4 disk; `ferry-node run` boots that disk
as a virtual machine with a vmnet address and everything it needs to join on the
kernel command line. It is never run as a container.

`ferry-node` is written against `Virtualization.framework` and Apple's
Containerization package, and is the seed of what docs/MACHINES.md calls
`ferry-machined`. It does the two things a Machine controller does per node. It
turns an image into a root filesystem, and it starts a machine that can join.

Run on macOS 26.6.2, Apple M1 Max, 10 cores, 32 GiB.

## Results

### It boots, joins, and runs pods with a working pod network

```
NAME             STATUS   VERSION    INTERNAL-IP    OS-IMAGE      KERNEL-VERSION   CONTAINER-RUNTIME
ferry-node-img   Ready    v1.34.11   192.168.79.2   Debian 12     6.18.5-ferry     containerd://2.3.5

NAME    READY   STATUS    IP           NODE
smoke   1/1     Running   10.88.0.2    ferry-node-img
--- logs ---
POD_ON_NODE_IMAGE
EGRESS_OK
```

`EGRESS_OK` is the line worth noticing. Experiment 17 had to disable `ipMasq`
and portmap because the base image carried no `iptables`, which cost pods their
route out. This image has it, so a pod reaches the internet through its node.

### Services and cluster DNS work

A node with no kube-proxy has no Services, and cluster DNS is reached through
one, so the missing DNS was really a missing kube-proxy. Mode 1 does not need
it: ferry runs kube-proxy's rule generation on the Mac and pushes the ruleset
into each pod's own kernel, because there is no shared node kernel to program.
A node VM has one, so the ordinary arrangement applies and Services go back to
being Kubernetes' problem.

The fix is kube-proxy as a DaemonSet, CoreDNS as a Deployment behind a
ClusterIP, and the kubelet told that address on the kernel command line.
`./verify.sh`:

```
  PASS  node is Ready
  PASS  kube-proxy is Running
  PASS  CoreDNS is Ready
  PASS  probe pod runs
        DNS_CLUSTER_OK          nslookup kubernetes.default.svc.cluster.local
        DNS_EXTERNAL_OK         nslookup example.com
        CLUSTERIP_OK            https://kubernetes.default.svc/healthz -> ok
        EGRESS_OK               a pod reaching the internet
```

`CLUSTERIP_OK` is a pod reaching the API server through `10.96.0.1`, which
means kube-proxy programmed the node and the Service routed.

| | |
|---|---|
| VM started | 0.09s |
| network configured, in-guest | 40ms |
| containerd answering | 147ms |
| kubelet registered | 12.5s |
| **boot to Ready** | **13.8s** |

This is slower than experiment 17's 6.5s, because this is a real init bringing
up a real machine from a disk. Almost all of it is the kubelet between "process
started" and "registered". Both numbers are far inside what the provisioner
needs. A cloud autoscaler's node takes 60 to 120 seconds.

### The disk costs what it holds, not what it claims

```
8192 MiB apparent
 387 MiB actually on disk
```

It is sized generously on purpose. A node whose root filesystem fills up reports
DiskPressure and evicts everything on it, and the file is sparse, so the extra
size is nearly free.

### Four more things a machine needs that a container does not

Experiment 17 found four. Building the image properly answered those and found
four more:

- **PID 1 gets an empty environment.** No `PATH`. Everything in the init calls
  binaries by absolute path and never noticed, until the kubelet shelled out
  to `mount` for a projected ServiceAccount volume and could not find it. Pods
  sat in `ContainerCreating` with the reason three layers down an event message.
- **`/etc/hosts` cannot be baked in.** A Docker build bind-mounts it read-only,
  so `RUN ... > /etc/hosts` fails outright. The init writes it at boot, which it
  must do anyway because containerd copies it into every sandbox.
- **Readiness checks must not block.** `ctr version` waits on containerd's socket
  rather than failing, so a readiness loop built on it hangs forever instead of
  retrying. Waiting for the socket file to appear is the check that works.
- **A certificate does not fit on a kernel command line.** Per-node
  configuration travels on a second small ext4 disk, a config drive, built
  from scratch per machine and mounted at boot.

One bug of my own is worth recording, because it fails silently. An
`InputStream` handed to the ext4 formatter reads nothing unless it is opened
first, which produced a config disk carrying a zero-byte certificate. The node
mounted it, reported `ca.crt present`, and then could not authenticate.

## What this means

- **The node image works**, and `ferry-node` build and run is the shape
  `ferry-machined` needs. An image goes in and a machine comes out.
- **Boot to Ready is 13.8s**, still fast enough that nodes are disposable and
  consolidation can be aggressive.
- **Cluster DNS and Services work**, which took kube-proxy rather than anything
  DNS-specific. Milestone 1 has nothing outstanding.

## Caveats

- **One node, one cluster.** Cross-node pod networking is milestone 3. This
  node's pods live on its own bridge, and nothing routes between two nodes yet.
- **The control plane is a throwaway** on shifted ports, not a `ferry up`
  cluster.
- **Addons are applied by the runner**, not by ferry. A real cluster would carry
  kube-proxy and CoreDNS as part of bringing a mode 2 cluster up.
- **The image is Debian-based and built by Docker.** Nothing requires that. It
  makes the build readable to anyone who has used a Dockerfile.

- **Boot-to-Ready is one measurement** on an otherwise idle Mac, and most of it
  is the kubelet's own startup rather than anything ferry controls.

## Reproduce

```sh
../17-node-vm/stage.sh   # kubelet, containerd, runc, CNI plugins
./build.sh               # image -> OCI layout -> ext4 disk, and the tool
./run.sh                 # control plane, token, machine, boot-to-Ready
KEEP=1 ./run.sh          # and leave it up to schedule pods against
./verify.sh              # node, addons, DNS, ClusterIP and egress, against a KEEP=1 cluster
FERRY_NODE_VERBOSE=1 KEEP=1 ./run.sh   # with the guest's whole console
```
