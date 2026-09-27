# Experiment 17: A Linux node VM that joins, and how fast

**Question.** [docs/MACHINES.md](../../docs/MACHINES.md) milestone 1: can a
Linux node VM boot on this Mac and join ferry's native control plane, and how
long does boot-to-Ready take? That number decides the provisioner's design.
Single-digit seconds means nodes are disposable and consolidation can be
aggressive. A minute means warm pools and something more careful.

**Method.** ferry's own control plane, native on the Mac. One VM booted through
`ferry-cri`, carrying containerd 2.3.5, runc 1.5.1, the CNI plugins and kubelet
v1.34.11, the same version the control plane is built at. The kubelet
bootstraps with a token, gets its certificate through a CSR the cluster
approves, registers, and goes Ready. Pods scheduled to it are ordinary Linux
containers sharing that one kernel.

Run on macOS 26.6.2, Apple M1 Max, 10 cores, 32 GiB.

## Results

### It joins, and it is Ready in six and a half seconds

```
NAME           STATUS   VERSION    INTERNAL-IP     OS-IMAGE      KERNEL-VERSION   CONTAINER-RUNTIME
ferry-node-1   Ready    v1.34.11   192.168.122.3   Debian 12     6.18.5-ferry     containerd://2.3.5
```

| run | boot to Ready |
|---|---|
| 1 | 6.4s |
| 2 | 6.5s |
| 3 | 6.5s |

From inside the guest, measured from its own first instruction:

| | |
|---|---|
| binaries unpacked | 1.25s |
| containerd answering | 1.40s |
| kubelet registered as a Node | 1.82s |

So roughly two seconds of guest work, and the rest is the VM and the pod around
it: image, boot, and the runtime's own sandbox setup. Six seconds is the number
milestone 1 asked for, and it is the one the provisioner design wanted. A node
can be created in response to a pending pod, and the pod waits about as long
as a slow image pull. Warm pools are an optimisation, not a
requirement.

For comparison, a cloud autoscaler's node takes 60–120 seconds.

### Pods run on it

```
NAME    READY   STATUS    IP          NODE
smoke   1/1     Running   10.88.0.2   ferry-node-1
--- logs ---
POD_ON_NODE_VM
```

The cluster's own scheduler placed it, containerd inside the VM pulled it
(4 MiB image in 1.17s), the CNI bridge addressed it, and `kubectl logs` reads
it back through the kubelet's API. With the image already present, three more
pods reached Running in 0.86s, 0.84s and 0.99s end to end. That covers kubectl
to scheduler to kubelet to containerd to CNI. It is not a CRI-level figure, so
it is not the same measurement as experiment 16's 45 ms per container.

### Four ways a container is not a machine

Each of these stopped the node dead, and each is a line item for the node image:

- **`/proc/sys` is read-only.** The kubelet's ContainerManager sets
  `vm/overcommit_memory`, `kernel/panic` and `kernel/panic_on_oops` at startup
  and refuses to run when it cannot. Remounting it read-write fixes it here. A
  real node boots with a writable `/proc` and never meets this.
- **Eviction thresholds are sized for a Mac, not for a node VM.** ferry's own
  `nodefs.available: 4Gi` against this VM's 2.2 GiB root filesystem means
  DiskPressure from the first heartbeat, and the node evicted everything
  scheduled to it. The first pod was `Evicted` before anything else was wrong.
- **No `iptables`.** The CNI bridge plugin needs it for `ipMasq`, and portmap
  needs it too. Without it every sandbox fails to set up its network. This run
  disabled both, which costs outbound NAT from pods. A node image has to carry
  iptables or nftables with the legacy shim. ferry already ships `nft` into
  pods for the same reason.
- **No `/etc/hosts`.** containerd builds each sandbox's hosts file from the
  node's own and refuses to start a sandbox without one. A machine has these
  files, but a container image need not.

None of these are about virtualization. They are the difference between an
image built to be a container and an image built to be a node, and they are the
argument for building the second rather than reusing the first.

## What this means

- **Milestone 1 is met**, and the number it exists to produce is six seconds.
- **Consolidation can be aggressive.** Deleting a node costs six seconds to
  replace, so the provisioner in docs/MACHINES.md can reclaim empty machines
  quickly rather than hoarding them. Since deleting a VM is the only thing that
  returns memory to the host ([experiment 14](../14-balloon/FINDINGS.md)), that
  matters more here than it does in a cloud.
- **The node image is the next piece of work**, and the list above is most of
  its specification: a writable `/proc`, its own disk sizing, iptables, and the
  ordinary files a Linux system has.

## Caveats

- **This is not a node image.** It is a `ferry-cri` pod VM with a node's
  software staged into it over a shared directory, which is why the four
  problems above are problems at all. The kernel, hypervisor, containerd, CNI
  and kubelet are real. The packaging is deliberately temporary.
- **No cluster DNS**, so pods fall back to the node's resolver. CoreDNS on a
  node VM is not yet tried.
- **One node.** Cross-node pod networking (one vmnet network, per-node CIDR,
  routes) is milestone 3 and is untouched here, as is anything about Services
  reaching across machines.
- **No `ipMasq`**, so a pod on this node cannot reach the internet through the
  node's NAT. It can talk on its bridge and to the node.
- **The control plane is a throwaway** on shifted ports, built by
  `control-plane/up.sh`, not a `ferry up` cluster.

## Reproduce

```sh
./stage.sh     # kubelet, containerd, runc, CNI plugins, CA bundle
./run.sh       # control plane, bootstrap token, node VM, boot-to-Ready
KEEP=1 ./run.sh   # and leave it running to schedule pods against
```

`run.sh` prints `BOOT_TO_READY_SECONDS` and leaves `kubectl` usable through the
kubeconfig it writes under its state directory.
