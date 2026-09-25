# Installing ferry

```sh
curl -sfL https://get.ferry.kurpuis.com | sh -
```

One line, no `sudo`, no toolchain. This is deliberately the k3s shape, because
it is the shape people already know, and because the alternative — clone, install
Swift 6.4, install Go, compile a kubelet from a patched Kubernetes tree, build a
guest kernel under Docker — is a reasonable thing to ask of someone changing
ferry and an unreasonable thing to ask of someone trying it.

## What it does

1. Checks the Mac can run ferry at all: Apple silicon, macOS 26 or newer. This
   happens before anything is downloaded, so a Mac that cannot run pods learns
   it in a line rather than after 300 MB.
2. Resolves the latest published release and downloads its tarball and checksum
   from GitHub Releases.
3. Verifies the checksum, unpacks into `~/.ferry-dist/versions/ferry-<version>`,
   and points `~/.ferry-dist/current` at it.
4. Links `ferry` into the first writable of `/usr/local/bin` then
   `~/.local/bin`, and says so if that directory is not on your `PATH`.
5. Installs a matching `kubectl` there if you do not already have one.
6. Registers a LaunchAgent so the cluster starts at login.
7. Runs `ferry up` — or `ferry join`, if `FERRY_URL` and `FERRY_TOKEN` are set.

## The install paths

Every way in, and what each is for.

### Install and run — the default

```sh
curl -sfL https://get.ferry.kurpuis.com | sh -
```

Downloads the latest release, verifies it, links `ferry` and `kubectl`,
registers the login agent, and starts a cluster.

### Install without starting anything

```sh
curl -sfL https://get.ferry.kurpuis.com | FERRY_SKIP_START=1 FERRY_SKIP_SERVICE=1 sh -
```

Nothing binds a port, claims a vmnet subnet, or touches `~/.ferry`. Useful on a
Mac that already runs a cluster from a checkout, and for looking before leaping:
`ferry doctor` afterwards says whether this machine can run it.

### A particular version

```sh
curl -sfL https://get.ferry.kurpuis.com | FERRY_VERSION=v0.1.0 sh -
```

Releases are listed at
[github.com/imaustink/ferry/releases](https://github.com/imaustink/ferry/releases).
Without this the installer asks the API for the latest **published** release —
deliberately the API rather than the `/latest` redirect, so a draft the
maintainer has not finished is never installed.

### From a mirror, an air-gapped copy, or a release you built

```sh
FERRY_VERSION=v0.1.0 \
  FERRY_DOWNLOAD_BASE="file://$PWD/dist" \
  sh install.sh
```

`FERRY_DOWNLOAD_BASE` replaces the GitHub URL the tarball and its checksum come
from; a `file://` URL works. It needs `FERRY_VERSION`, because there is no
releases API behind it to ask which version to take. The checksum is still
verified.

### Join a cluster on another Mac

```sh
curl -sfL https://get.ferry.kurpuis.com | \
  FERRY_URL=mac1.local:6443 FERRY_TOKEN=F10… sh -
```

Installs, then joins instead of starting a cluster of its own. See
[Adding nodes](#adding-nodes). Run it from a Terminal window on that Mac, not
over SSH.

### Build from source

For changing ferry. Needs Swift 6.4, Go 1.24+, and Docker for the guest kernel
and the mode 2 node image.

```sh
git clone https://github.com/imaustink/ferry && cd ferry
./ferry doctor        # checks the toolchain, not just the machine
./ferry build         # kubelet, runtime, daemons, control plane, CNI
./ferry kernel        # guest kernel with NAT support (slow, needs docker)
./ferry node-image    # mode 2 node image (slow, needs docker)
./ferry up
```

`ferry build` alone is enough for mode 1 with Services routed through a host
proxy. `ferry kernel` is what lets Services route inside pods without root.

A checkout and an installed release can coexist: a checkout in a git worktree
gets its own profile, and so its own state, ports and pod network. See
[PROFILES.md](PROFILES.md).

### Upgrade

Run the installer again. It unpacks beside the old release and moves
`~/.ferry-dist/current`, so every launcher and the login agent follow without
being relinked. The previous version stays on disk.

This also moves **Kubernetes**, because a release carries one. See
[Upgrading ferry](#upgrading-ferry).

### Uninstall

```sh
ferry uninstall             # stop, deregister, unlink; keep the cluster's data
ferry uninstall --purge     # and delete ~/.ferry
```

## Adding nodes

Three different things get called "adding a node". They are not
interchangeable.

| | what it adds | isolation |
|---|---|---|
| `ferry node add` | another kubelet on **this** Mac | a VM per pod |
| `ferry join` | **another Mac** | a VM per pod |
| a `Machine` | a Linux node VM on this Mac | pods share its kernel |

### Another node on the same Mac

```sh
ferry node add worker-1
ferry node ls
ferry node rm worker-1
```

Each gets its own runtime, streamer and kubelet, its own `/24` of the cluster
CIDR, and ports offset from the first node's. It is one Mac's memory either
way, so this is for testing scheduling and multi-node behaviour rather than for
capacity.

**Each node has its own credential.** `ferry node add` signs the node a kubelet
client certificate with the cluster CA, `CN=system:node:<name>` in
`O=system:nodes`, kept in `~/.ferry/pki/nodes/<name>.{crt,key,conf}`. A Mac
that joined gets its node's the Kubernetes way, a bootstrap token and a CSR
the control plane approves. Either way the Node authorizer and the
NodeRestriction admission plugin give a node its own Node, its own pods and
what they mount, and nothing of anyone else's: as any node,
`kubectl auth can-i list secrets -A` and `list pods -A` both say `no`, and
changing another node or deleting its pods is refused. Nodes can read the Node
list, Services and EndpointSlices (upstream's `system:node-proxier`, bound as
`ferry-node-proxier`), which is how each Mac renders its own Service rules.

A cluster made before this bound the whole `system:node` role to every node
(`ferry:system-nodes`), because added nodes all ran on the first node's
certificate. The next `ferry up` or `ferry upgrade apply` deletes that binding,
and first restarts the kubelet of any added node still on the first node's
certificate onto one of its own; its runtime and pods stay up. `ferry node rm`
deletes the node's key.

### Another Mac

On the Mac already running the cluster:

```sh
ferry token create
```

It prints the exact line to run on the other Mac — the installer with
`FERRY_URL` and `FERRY_TOKEN` set, or `ferry join` if that Mac already has
ferry:

```sh
ferry join --server mac1.local:6443 --token F10…
```

Both Macs need to reach each other on the LAN. The token is good for **24
hours** and is reusable.

**The token is one string.**

```
F10<64 hex of the CA's public key>::<id>.<secret>
```

The hash is not a secret — it is a fingerprint of a public key, published in
`kube-public` for anyone to read. It rides along because the joining Mac fetches
the CA over a connection it cannot yet verify and has to pin what it gets
against something; a token that carries the pin is a token that cannot be used
without it. This is kubeadm's discovery, and k3s' token shape, for the same
reasons.

A truncated paste does not parse. That matters more than it looks: if it did
parse, the pin would be checked against a short hash, fail, and report a CA
mismatch — a security-shaped error for a copy-and-paste mistake.

The older three-flag form still works, for a token minted by an older ferry:

```sh
ferry join --server host:6443 --token <id.secret> --ca-hash sha256:<hash>
```

**Pod network slices.** Every node owns one `/24` of the cluster CIDR, chosen by
its node index, and two nodes on the same index hand out the same pod addresses.
A joining Mac picks a free one itself by reading the other nodes'
`ferry.dev/node-index` labels. A kubelet only registers that label when it
*creates* the Node object, so nodes from a cluster built before the label
existed never carry one; with more than one such node ferry declines to guess
and asks for `--node-index`:

```sh
kubectl get nodes -L ferry.dev/node-index
ferry join --server host:6443 --token F10… --node-index 3
```

**Not over SSH.** macOS grants local network access per session, and a node
started from a session that ends loses the network about twenty seconds later —
"no route to host" against an address that answers ping. `ferry join` refuses an
SSH session and explains it; `FERRY_ALLOW_SSH_JOIN=1` overrides it, knowing the
node will stop working when the session closes.

**Removing a Mac.** Run `ferry down` on it, then `kubectl delete node <name>`
from the cluster. `ferry down` stops processes; it does not leave the cluster.

**What a joined Mac does not do:** come back on its own after a reboot. A
worker's kubelet certificate and kubeconfig live under `/tmp`, so rejoin it with
a fresh token. See [Starting at login](#starting-at-login).

### A machine — mode 2

```sh
ferry machines enable
kubectl apply -f - <<'EOF'
apiVersion: ferry.dev/v1alpha1
kind: Machine
metadata: {name: worker-0}
spec: {cpus: 2, memory: 2Gi}
EOF
```

A node VM on this Mac whose pods are ordinary Linux containers sharing its
kernel. `kubectl delete machine worker-0` takes it away — VM stopped, Node
removed, disk cleaned up. See [Machines — mode 2](#machines--mode-2).

## Configuration

What a cluster is meant to be lives in one file beside its state,
`~/.ferry<-profile>/config.yaml`, shaped like the configuration files
Kubernetes components read:

```yaml
apiVersion: ferry.dev/v1alpha1
kind: FerryConfig
purpose: dev              # dev | ci | node -- recorded, not acted on
durability: power-loss    # power-loss | process-crash
machines: true            # whether mode 2 runs
```

`ferry init` asks what the cluster is for and writes it. Each purpose starts
from sensible answers and every one is asked about:

| purpose | machines | durability | for |
|---|---|---|---|
| `dev` | on, where available | `power-loss` | a laptop you develop on |
| `ci` | on, where available | `process-crash` | clusters a script creates and deletes |
| `node` | off | `power-loss` | an always-on node holding what you would rebuild by hand |

`ferry init --purpose ci --yes` answers from flags alone, for a script.

```sh
ferry config                         # every setting, its value, and where it came from
ferry config set durability process-crash
ferry config unset podMemoryMiB      # back to the default
```

The precedence is the usual one: a flag, for this run; a `FERRY_*` variable,
for this run; the file; the default. A flag that is meant to be remembered —
`ferry up --durability`, `ferry machines enable` — writes the file, and `ferry
up` names the file every time it starts, so a setting is never somewhere you
cannot see it. `ferry down --purge` deletes the cluster's data and keeps its
config, which is the point of having one; `ferry init --force` starts again.

Besides the three above, the file takes a few settings that are one
environment variable each: `podMemoryMiB` (`FERRY_POD_MEMORY_MIB`), `podCPUs`
(`FERRY_POD_CPUS`), `maxPods` (`FERRY_MAX_PODS`), `machineLimitCPUs`
(`FERRY_MACHINE_LIMIT_CPUS`) and `machineLimitMemoryGi`
(`FERRY_MACHINE_LIMIT_MEMORY_GI`).

**Before this file** the same choices were marker files — `durability` and
`machines-enabled` in `~/.ferry` — written by flags and read back without a
word. They are still read, and the first `ferry up`, `ferry config set` or
`ferry machines` moves them into the file and removes them. A ferry from before
this change does not read the file, so going back to one loses those two
settings.

## Parameters

Everything below is an environment variable. The installer's are read by
`install.sh` at install time; the rest are read by `ferry` every time it runs, so
they belong in the shell that runs `ferry up`, `ferry join` or the login agent —
not in the installer.

### Installing

| | default | |
|---|---|---|
| `FERRY_VERSION` | latest published | the release to install |
| `FERRY_URL` | — | an existing cluster's API server; makes this a join |
| `FERRY_TOKEN` | — | the token from `ferry token create` |
| `FERRY_NODE_NAME` | the Mac's short hostname | what to call this node |
| `FERRY_INSTALL_DIR` | `~/.ferry-dist` | where releases are unpacked |
| `FERRY_BIN_DIR` | `/usr/local/bin`, else `~/.local/bin` | where `ferry` is linked |
| `FERRY_SKIP_START` | — | `1` to install without starting a cluster |
| `FERRY_SKIP_SERVICE` | — | `1` to not register the login agent |
| `FERRY_SKIP_KUBECTL` | — | `1` to not install kubectl even if missing |
| `FERRY_DOWNLOAD_BASE` | the release's GitHub URL | where to fetch the tarball; needs `FERRY_VERSION` |
| `FERRY_REPO` | `imaustink/ferry` | which repository to install from |

### Which cluster, and where it lives

| | default | |
|---|---|---|
| `FERRY_PROFILE` | `default`, or the worktree's name | which cluster this is; decides ports, state and pod network |
| `FERRY_HOME` | `~/.ferry<-profile>` | etcd, PKI, kubeconfigs, logs — survives a restart |
| `FERRY_CONFIG` | `$FERRY_HOME/config.yaml` | this cluster's settings; see [Configuration](#configuration) |
| `FERRY_RUN` | `/tmp/ferry-run<-profile>` | sockets, pid files, per-run state. Under `/tmp` because macOS caps a unix socket path near 104 bytes |
| `FERRY_PROFILES` | `~/.ferry-profiles` | the register mapping profile names to index numbers |
| `FERRY_NODE_NAME` | `ferry-mac<-profile>` | this node's name |
| `FERRY_LAN_IP` | `en0`, else `en7`, else loopback | the address other Macs reach this one on |

### Pods

| | default | |
|---|---|---|
| `FERRY_POD_CPUS` | `2` | cpus per pod VM |
| `FERRY_POD_MEMORY_MIB` | `512` | memory per pod VM |
| `FERRY_POD_READAHEAD_KB` | `1024` | read-ahead, in KiB, of a pod's image disks, scratch disk, disk emptyDirs and block claims. The guest agent's own disk always stays at 128 KiB. A pod can ask for its own with the annotation `ferry.dev/read-ahead-kb`. Higher streams large files faster and costs a pod with one large binary more memory: node is 17 MiB more at 1024, 48 at 8192 ([experiment 36](../experiments/32-pod-memory-footprint/FINDINGS.md#read-ahead-on-the-pods-own-disks-experiment-36)) |
| `FERRY_MAX_PODS` | derived from RAM, capped at 110 | how many pods this Mac advertises. An idle pod VM costs ~133 MiB whatever the workload does, so half of memory is budgeted for that |
| `FERRY_EVICTION_DISK` | `4Gi` | free disk below which pods stop scheduling |
| `FERRY_EVICTION_MEMORY` | `500Mi` | free memory below which the kubelet evicts |
| `FERRY_INSECURE_REGISTRIES` | — | registries pods may pull from over plain HTTP, comma separated, `host` or `host:port`. Loopback and this Mac's own addresses always are, which is what makes `ferry addons enable registry`'s `localhost:5001` work; everything else is HTTPS. Read by `ferry-cri` when ferry starts |

### Addons

| | default | |
|---|---|---|
| `FERRY_ADDON_CACHE` | `$FERRY_HOME/cache/addons` | where pinned upstream manifests are kept, by sha256, so an addon enabled once enables again with no network |
| `FERRY_ADDON_TIMEOUT` | the addon's own, else `300` | seconds `ferry addons enable` waits for rollouts and checks |

### Durability and speed

`ferry up --disposable` (durability `process-crash`) sets the first two together and is the
supported way in; the rest are here because the code reads them and are worth
knowing when one of them is the thing you want to change on its own.

| | default | |
|---|---|---|
| `FERRY_DURABILITY` | `power-loss` | `process-crash` to acknowledge writes before they reach the disk: a crashed process loses nothing, a power loss or kernel panic can. Overrides what the cluster was created with, for one run, without changing it. `ferry up --durability` is the same choice, remembered. `full` and `relaxed`, the old names, still work |
| `FERRY_ETCD_NO_FSYNC` | — | `1` to start etcd with `--unsafe-no-fsync`. Set for you by `process-crash`. On macOS Go's `os.File.Sync()` is `fcntl(F_FULLFSYNC)`, a flush of the drive's own write cache — 3.96ms here against 0.031ms for plain `fsync(2)`, and every pod status update is an etcd write |
| `FERRY_NODE_DISK_SYNC` | `fsync` | `none` to drop the barrier on a machine's virtual disk, `full` for the strictest. Set for you by `process-crash` |
| `FERRY_BUILDER_CPUS` | half the Mac's cores, at least 2 | CPUs for the `ferry image build` builder pod. buildkit on the pod default of 2 is roughly half the speed of 8 |
| `FERRY_BUILDER_MEMORY_GIB` | a quarter of the Mac's memory, 2–8 | memory for the builder pod |
| `FERRY_BUILDER_POD` | `ferry-builder` | the builder pod's name |
| `FERRY_BUILDER_NS` | `kube-system` | the namespace it runs in |
| `FERRY_BUILDKIT_IMAGE` | `moby/buildkit:v0.29.0` | the buildkit image it runs |
| `FERRY_BUILDER_CN` | `ferry-builder` | the name in the builder's TLS certificate, which `buildctl --tlsservername` verifies against |
| `FERRY_NODE_USB` | set by ferry | `1` boots machines with a USB controller and attaches the disk images listed in `<machines-dir>/<name>.usb`, which `ferry-machined` writes for `ferry-local-block` claims. ferry sets it when the kernel carries usb-storage (every kernel `ferry kernel` builds now does); see `experiments/33-cluster-images-and-volumes` |
| `FERRY_BLOCK_CLASS` | `ferry-local-block` | the StorageClass whose ReadWriteOnce claims are disks on machines too -- attached over USB after boot, so `chown` works -- rather than directories in the virtiofs share. Offered only when the kernel carries usb-storage, and needs a node image with its `ferry.dev/block` driver (`ferry node-image`). Synced small writes are about a third as fast as the share's |
| `FERRY_KUBE_API_QPS` | `500` | how fast a kubelet may talk to the API server. Upstream's 50 paces a 20-pod burst at 40ms a pod, with every container already running |
| `FERRY_KUBE_API_BURST` | `1000` | the burst that goes with it |
| `FERRY_KUBELET_V` | `2` | klog level for both kubelets. At `4` the kubelet logs its own per-pod phase boundaries, which is what `experiments/24-benchmark-harness/syncphases.py` reads |
| `FERRY_VOLUME_RECONCILE_MS` | `10` | the volume manager's reconciler period, patched into the kubelet at build time. Upstream is 100 |
| `FERRY_VOLUME_POPULATE_MS` | `10` | its desired-state populator period. Upstream is 100 |
| `FERRY_VOLUME_RETRY_MS` | `20` | how often `WaitForAttachAndMount` re-checks. Upstream is 300. Together these three were ~290ms of sleeping on the critical path of every pod start |
| `FERRY_CRI_TRACE` | unset | `1` makes `ferry-cri` log how long each CreateContainer and StartContainer took, and each pod VM boot by phase, to the ferry-cri log. What `experiments/31-restart-in-place` measures with |

### Networking

| | default | |
|---|---|---|
| `FERRY_CLUSTER_CIDR` | `10.244.0.0/16`, or `10.<150+index>.0.0/16` | the pod network every node slices. Empty returns to vmnet addressing and a single node |
| `FERRY_POD_SUBNET` | `192.168.66.1/24` | the vmnet subnet pods get their interface on |
| `FERRY_CLUSTER_DOMAIN` | `cluster.local` | the cluster's DNS domain |
| `FERRY_COREDNS_IMAGE` | `docker.io/coredns/coredns:1.11.3` | the CoreDNS mode 1 runs, and mode 2's machines run |
| `FERRY_NODE_INDEX` | `0` | which `/24` of the cluster CIDR this node owns |
| `FERRY_RELAY_PORT` | `8472` + profile shift | udp port the pod switch uses between Macs. The base of a range, not one port: node N added with `ferry node add` uses this plus N, up to 99 |
| `FERRY_NETPOL_PEER_PORT` | `6444` + profile shift | on the control plane's Mac: the TLS port its ferry-netpol serves the other Macs' nodes their own pods' NetworkPolicy rules on. Only a kubelet client certificate the cluster CA signed, in `system:nodes`, is answered, and only with that node's pods |
| `FERRY_NETPOL_UPSTREAM` | the join address's host, its port + 1 | on a joined Mac: where to follow the control plane's ferry-netpol, for a control plane whose peer port is not one above its API server's |
| `FERRY_PEERS` | read from `$FERRY_HOME/peers` | the other Macs' relay endpoints |
| `FERRY_ALLOW_OFF_SLICE` | — | `1` to start when vmnet will not give this node its slice. Other nodes will not reach these pods; without it ferry refuses rather than partition silently |
| `FERRY_HOST_CLUSTER_IPS` | `false` | `1` to bind ClusterIPs on the Mac too, so the API server reaches aggregated APIs. Needs sudo |
| `FERRY_STREAM_ADDR` | `127.0.0.1:10350` + shift | where the streaming server listens |
| `FERRY_CNI_CONFLIST` | ferry's own | a CNI conflist to use instead |
| `SERVICE_CIDR` | `10.96.0.0/16` | the Service network. Read by `control-plane/up.sh` |

### Machines

| | default | |
|---|---|---|
| `FERRY_NODE_IMAGE` | `<root>/node-image/oci` | the OCI layout machines are built from |
| `FERRY_NODE_DISK` | `$FERRY_HOME/node.ext4` | the disk unpacked from it, cloned per machine |
| `FERRY_MACHINE_SUBNET` | `192.168.<200+index>.0/24` | the one vmnet network every machine sits on |
| `FERRY_MACHINE_DNS_IP` | `10.96.0.10` | the ClusterIP machines resolve through |
| `FERRY_KUBE_PROXY_IMAGE` | `registry.k8s.io/kube-proxy:v1.34.11` | kube-proxy inside machines |
| `FERRY_MACHINE_LIMIT_CPUS` | half the Mac's cores | total cpus the provisioner may commit to machines |
| `FERRY_MACHINE_LIMIT_MEMORY_GI` | a quarter of the Mac's memory | total memory it may commit. Past this, a pod stays `Pending` with a reason rather than the Mac swapping |
| `FERRY_MACHINE_MIN_CPUS` / `FERRY_MACHINE_MAX_CPUS` | `2` / `8` | how small and how large one provisioned machine may be |
| `FERRY_MACHINE_MIN_MEMORY_GI` / `FERRY_MACHINE_MAX_MEMORY_GI` | `2` / the total memory limit | the same for memory. The max is held to the total by default, since one machine cannot exceed what every machine may be |
| `FERRY_MACHINE_RELAY_PORT` | `8700` + profile shift | where machines join ferry's pod network. `ferry-node` holds this end of the switch and `ferry-cri` the other, both on loopback, so machines and mode 1 pods land on one segment. Clear of `FERRY_RELAY_PORT`, which is a range rather than a port: node N's switch is `FERRY_RELAY_PORT` + N |
| `FERRY_MACHINE_MAX_PODS` | `110` | pods a provisioned machine advertises. Kubernetes' own default, not mode 1's memory-derived number: pods in a machine share its kernel |
| `FERRY_MACHINE_IMAGE` | — | node disk for provisioned machines, if it should differ from `FERRY_NODE_DISK`. Rarely wanted |
| `FERRY_NODE_VERBOSE` | — | set to print a machine's whole console, kernel included, into `ferry logs ferry-node`. The first thing to reach for when a machine never goes Ready |
| `FERRY_NODE_NO_CONFIG` | — | set to boot a machine without its generated config disk. For debugging the image itself |
| `FERRY_MACHINE_REGISTRY` | `1` | `0` to stop sharing loaded images between nodes. With it on, `ferry-registry` keeps what `ferry image load` and `ferry image build` load in `$FERRY_HOME/registry` and serves it read-only to every node that is not the one it was loaded on: `ferry-cri` on every node of this Mac asks it before the real registry, every machine's containerd does the same at the machine network's gateway, and it asks the other Macs' registries for any name it does not hold. Anything not stored falls through to the real registry. `ferry image load` also loads into the other nodes on this Mac, so `imagePullPolicy: Never` works on them; machines and other Macs need `IfNotPresent` |
| `FERRY_MACHINE_REGISTRY_PORT` | `5050` + profile shift | the port it serves this Mac on: loopback and the machine network only. Not 5000, which macOS's AirPlay receiver holds |
| `FERRY_REGISTRY_PEER_PORT` | `5051` + profile shift | the port it serves the cluster's other Macs on, over TLS. Both ends present their node's kubelet certificate, and only a certificate the cluster CA signed in group `system:nodes` is answered, so the LAN and pods are refused. The same number on every Mac of a cluster: each works out the others' from its own |
| `FERRY_NODE_REGISTRY_PORT` | set by ferry | what `ferry-node` reads to put `ferry.registry=<port>` on a machine's command line. ferry sets it from the two above, and blanks it when the registry is off; not meant to be set by hand |

The two `MIN`/`MAX` pairs bound one machine; the two `LIMIT`s bound all of them
together. They are separate numbers on purpose — collapsing them gives either a
single machine that can eat the whole budget, or a budget that silently caps how
large any one machine can be. Between them they decide the shapes the
provisioner offers: powers of two within the cpu range, each with memory at 1×,
2× and 4× its cores, clipped to the memory range.

The machine range is also the only sizing decision left. Nothing declares a
machine in the ordinary case: a pod that fits no existing node produces one, and
an empty machine is reclaimed about a minute later.

### GPU

| | default | |
|---|---|---|
| `FERRY_GPU_CAPACITY` | `1` | how many pods may hold the GPU at once |
| `FERRY_GPU_SLICE` | `0.5` | how long one request holds it before a waiting pod gets a turn |

### Versions and building

| | default | |
|---|---|---|
| `K8S_VERSION` | what is built, else `v1.37.0` | the Kubernetes to build |
| `K8S_CONTROL_PLANE_VERSION` | pinned per minor | the darwin control plane build, when ferry's pin is not published |
| `ETCD_VERSION` | paired with the Kubernetes | the etcd to fetch |
| `K8S_SRC` | under `$TMPDIR` | where the Kubernetes source tree is checked out |
| `FERRY_REBUILD` | — | `1` to rebuild rather than reuse what is built |

### Upgrades and joining

| | default | |
|---|---|---|
| `FERRY_KUBECONFIG` | the admin one | admin credentials, for upgrading a Mac that joined and so has only its kubelet's certificate |
| `FERRY_DRAIN_TIMEOUT` | `300s` | how long to wait for a node to drain |
| `FERRY_SKIP_SNAPSHOT` | — | `1` to skip the etcd snapshot an upgrade takes first. Do not |
| `FERRY_ALLOW_REMOVED_APIS` | — | `1` to upgrade although something is still asking for an API the target removes |
| `FERRY_RECORD_SIGNATURES` | — | `1` to have `build-kubelet.sh` record the constructors a newly ported `patches/kubelet-vX.Y/` is written against |
| `FERRY_WATCH_GRACE` | `2s` | how long a stopping API server gives its watches to end before it exits |
| `FERRY_KEEP_ETCD`, `FERRY_HANDOVER`, `FERRY_HANDOVER_BIN` | set by `upgrade` | how `control-plane/up.sh` replaces a running control plane: keep etcd, and hold the API server's port with `bin/ferry-handover` while one API server hands over to the next |
| `FERRY_ALLOW_SSH_JOIN` | — | `1` to join over SSH, knowing the node loses the network when the session ends |
| `FERRY_INSTALL_URL` | `https://get.ferry.kurpuis.com` | the installer URL ferry prints in `token create` |

### Internal

Derived from the profile, and overridable, but changing one without changing
the rest is how a cluster half-talks to itself. The profile is the supported
way to move them all at once, and `ferry profile` prints what this one resolved
to.

`FERRY_SOCK`, `FERRY_EXEC_SOCK`, `FERRY_STREAMER_SOCK`, `FERRY_PROXYD_SOCK`,
`FERRY_NETPOL_SOCK`, `FERRY_GPUD_SOCK`, `FERRY_GPU_DIR`, `FERRY_ROOT`,
`FERRY_CONTAINER_LOGS_DIR`, `ETCD_CLIENT_PORT`, `ETCD_PEER_PORT`,
`SERVICE_NODE_PORT_RANGE`.

### Keeping this list honest

These are not all read in the same place, which is why the list drifted before:
most are read by `ferry` and `install.sh` in shell, `SERVICE_CIDR` and the etcd
ports by `control-plane/up.sh`, and `FERRY_ALLOW_OFF_SLICE`, `FERRY_CRI_TRACE`,
`FERRY_NODE_VERBOSE` and `FERRY_NODE_NO_CONFIG` by the Swift binaries through
`ProcessInfo.environment` — where no amount of grepping the shell finds them.

To check nothing has been added without being written down:

```sh
grep -rhoE '\$\{(FERRY|K8S|ETCD|SERVICE)_[A-Z0-9_]+' ferry install.sh lib control-plane \
  | sed 's/.*{//' | sort -u
grep -rhoE 'environment\["[A-Z0-9_]+"\]' ferry-cri/Sources experiments/18-node-image/Sources \
  | sed 's/environment\["//; s/"\]//' | sort -u
```

## Starting at login

```sh
ferry service status
ferry service install
ferry service uninstall
```

The installer registers this for you. It is a LaunchAgent, not a LaunchDaemon,
and that is not a detail:

- `Virtualization.framework` will not create a VM from a process outside a user
  session, so a daemon running before login could not start a pod.
- macOS grants local network access per session, and an agent lives in the login
  session, which is a session that stays.

So the cluster comes up at **login**, not at boot. On a Mac that is logged in and
stays logged in, the difference is invisible. On one that reboots to the login
window, the cluster waits there — which is the honest behaviour rather than a
daemon that starts and then cannot make a VM.

`launchd` restarts the cluster if it falls over, and does not restart one that
was stopped on purpose. It cannot tell those apart by itself — both end with the
processes gone — so `ferry down` leaves a marker in `~/.ferry/stopped` and
`ferry up` clears it. Without that, `ferry down` stopped the cluster and launchd
started it again five seconds later, and there was no way to turn ferry off at
all while the agent was registered.

The marker means *this session*, not forever: after a reboot the agent starts
the cluster again.

Registering the agent starts the cluster too — `RunAtLoad` does that — so
`ferry service install` on a Mac with a cluster already up holds the one that is
running rather than starting a second.

The agent's log is `~/.ferry/logs/service.log`.

**A Mac that joined another cluster does not come back on its own.** A worker's
kubelet certificate and kubeconfig live under `/tmp`, which is where they have to
be — macOS caps a unix socket path near 104 bytes and the kubelet builds its
podresources socket beneath `--root-dir`. Those do not survive a reboot, so the
agent says what happened and leaves it alone rather than starting a control
plane on a machine that is meant to be a worker. Rejoin with a fresh token.

## Machines — mode 2

A release carries mode 2, where the node is the VM and pods inside it are
ordinary Linux containers sharing its kernel ([MACHINES.md](MACHINES.md)). It is
**off until you ask for it**:

```sh
ferry machines enable
kubectl apply -f - <<'EOF'
apiVersion: ferry.dev/v1alpha1
kind: Machine
metadata: {name: worker-0}
spec: {cpus: 2, memory: 2Gi, node: {labels: {ferry.dev/mode: shared}}}
EOF
kubectl get machines
```

Off by default because of what mode 2 does *today*: it is complete through
milestone 3 — a `Machine` becomes a node, and pods on two machines reach each
other — but provisioning, consolidation and mixed-cluster scheduling are not
built. Starting two more daemons and holding a vmnet network on every cluster,
including the ones that will never declare a `Machine`, is not a fair default
for that. Enabling is remembered per cluster, so `ferry up` and the login agent
bring machines back.

The release ships the node image as an **OCI layout**, not as a disk. The first
`ferry machines enable` unpacks it to `~/.ferry/node.ext4` (~400 MB) using
`ferry-node`'s own unpacker — so Docker is not needed on the installing Mac.
It unpacks again whenever the layout changes, which means on every upgrade to a
release with a different node image, and after any `ferry node-image` — so the
~400 MB is paid once per node image rather than once per Mac. Machines that
already exist keep the disk they were given; delete and re-apply a `Machine` to
move it onto a new image.
Docker is only needed to *create* the layout, which happens on the machine
cutting the release:

```sh
./ferry build         # adds ferry-machined and ferry-node
./ferry node-image    # the node image itself (slow, needs docker)
```

A release can be built without it (`release/build.sh --without-node-image`); its
`VERSION` records that, and `ferry machines` says so rather than failing on a
missing directory. Mode 1 is unaffected either way.

### Choosing a mode

A pod picks with a RuntimeClass, the way it would pick Kata or gVisor:

```yaml
runtimeClassName: ferry-shared   # dense, one kernel for many pods
runtimeClassName: ferry-vm       # a kernel each
```

Each class is a node selector underneath, on the label `kubectl get nodes`
already shows, so the older spelling still works and places a pod identically:

```sh
kubectl get nodes -L ferry.dev/mode
```

```yaml
nodeSelector: {ferry.dev/mode: shared}       # same as ferry-shared
nodeSelector: {ferry.dev/mode: vm-per-pod}   # same as ferry-vm
```

The Mac node sets `vm-per-pod` on its own kubelet; `ferry-machined` labels each
machine `shared` once its node registers. `ferry up` installs both classes
(`manifests/runtimeclasses.yaml`). ferry-cri refuses a sandbox whose handler is
not its own, so a `ferry-shared` pod that somehow reaches the Mac fails with a
reason rather than quietly becoming a VM.

A pod that names neither goes wherever it fits unless the cluster has a
default; see `defaultRuntime` under [Configuration](#configuration).

### Cluster DNS inside machines

Machines resolve through their own CoreDNS, behind `kube-dns` at `10.96.0.10`,
with kube-proxy running on each machine to answer that address. `ferry machines
enable` installs both, pinned to `ferry.dev/mode: shared`; they stay `Pending`
until a machine exists to run them on.

Mode 1's CoreDNS cannot serve machines. It is a `ferry-cri` pod on the Mac's
vmnet network, machines are on a vmnet network of their own, and vmnet keeps its
networks apart — so a pod inside a machine has no route to it. Each mode
resolving through its own CoreDNS is the honest arrangement until cross-mode pod
routing exists, which is milestone 6. Nothing here changes mode 1: its kubelet
is told CoreDNS's pod address directly and never consults this Service.

`FERRY_MACHINE_DNS_IP` moves the address. A `kube-dns` Service that already
exists somewhere else is reported rather than applied over — a ClusterIP cannot
be changed once set.

## kubeconfig

```sh
ferry kubeconfig            # prints the path
ferry kubeconfig --merge    # adds it to ~/.kube/config as context "ferry"
```

The merge leaves your current context where it was, and gives each profile
its own cluster, user and context name (`ferry-e2e` for the `e2e` profile), so
two clusters on one Mac cannot end up sharing one API server's entry.

Merging is offered rather than done. `~/.kube/config` usually points at clusters
that matter, and an installer that rewrites it uninvited eventually ruins
somebody's afternoon. `--merge` backs the file up first, and uses kubectl's own
merge.

## Upgrading ferry

Run the installer again. It unpacks the new release beside the old one and moves
`~/.ferry-dist/current`, so every launcher and the LaunchAgent follow without
being relinked — which is why `current` exists and why ferry deliberately stops
resolving symlinks there rather than pinning itself to the version directory.

That also moves **Kubernetes**, because a release carries one: the kubelet,
`ferry-proxyd`, the control plane and etcd built and tested as a set. This is
k3s' model, and it is not a choice so much as a consequence — `ferry upgrade
apply` compiles a kubelet from a patched Kubernetes tree, and a release carries
neither the tree nor a toolchain. `ferry upgrade` says so and stops, rather than
finding out several minutes in.

In a checkout, where any version is a build input,
`ferry upgrade plan|apply|nodes|rollback` works as documented in
[UPGRADES.md](UPGRADES.md).

## Uninstalling

```sh
ferry uninstall             # stop the cluster, remove the agent, unlink the CLI
ferry uninstall --purge     # and delete ~/.ferry: etcd, the PKI, every object
```

Without `--purge` the cluster's state is kept, so reinstalling brings the same
cluster back. With it, there is no undo and no backup taken; it asks you to type
`yes` unless given `--yes`.

The release directory itself is left for you to `rm -rf`, because ferry is
executing out of it at the time.

## Where get.ferry.kurpuis.com comes from

GitHub Pages, published from `main` by
[`.github/workflows/pages.yml`](../.github/workflows/pages.yml) whenever
`install.sh` changes. The script is served at `/` and at `/install.sh`; the
workflow runs `sh -n` on it first, because a syntax error here is a broken
install command for every new user on a path no test of ferry would catch.

Publishing from `main` rather than keeping a copy on a `gh-pages` branch is the
point: a copy drifts, and the installer people run would slowly stop being the
one in this repository with nothing saying so.

**One-time setup**, which is DNS and a repository setting rather than anything
in this tree:

1. **DNS.** A `CNAME` record for `get.ferry.kurpuis.com` pointing at
   `imaustink.github.io`. Not an `A` record and not the apex — a nested
   subdomain as a `CNAME` is exactly the supported case. This one is declared
   in the homelab repository as an ExternalName Service that ExternalDNS turns
   into the record.
2. **Pages source.** In the repository's Settings → Pages, set the source to
   **GitHub Actions**. The workflow cannot set this itself: `configure-pages`
   fails with *"Get Pages site failed… verify that the repository has Pages
   enabled"* until it is set.
3. Push to `main`, or run the workflow by hand.
4. Once DNS resolves, tick **Enforce HTTPS**. GitHub issues a Let's Encrypt
   certificate for the subdomain automatically; it cannot do that until the
   `CNAME` record is in place, so this step comes last.

### The domain is two files that have to agree

The [`CNAME`](../CNAME) file at the root of this repository holds the domain,
and the workflow copies it into the published site. That copy is what binds the
domain on GitHub's side, and it has to match the DNS record pointing at Pages.

Keeping the domain in a tracked file rather than in a workflow step is so that
losing it takes deleting something on purpose. It does **not** remove the
dependency on the workflow: with the Pages source set to GitHub Actions, the
published site is only what the job uploads, so nothing in this repository is
served by itself. A deployment whose artifact lacks `CNAME` resets the domain
to `imaustink.github.io`, and the site stays up while every install command in
these docs stops working — which is why a test asserts the file exists, names
the same host as `install.sh`, and is copied into `_site`.

Serving the file directly, with no workflow at all, would mean switching Pages
to *Deploy from a branch*. That also needs the served content committed — an
`index.html` holding a second copy of `install.sh` — which is the drift this
arrangement exists to avoid.

Until all of that is done, the installer still works by naming the release
directly:

```sh
FERRY_VERSION=v0.1.0 \
  FERRY_DOWNLOAD_BASE=https://github.com/imaustink/ferry/releases/download/v0.1.0 \
  sh install.sh
```

`FERRY_INSTALL_URL` overrides the hostname ferry prints in `ferry token create`
and in its release-guard messages, for anyone serving the installer elsewhere.

## Notes

**Gatekeeper.** `curl` does not set `com.apple.quarantine`, so a piped install is
not blocked. A browser does, so the installer clears the flag anyway — a
quarantined binary is killed at launch with nothing useful said about why.

**Size.** The tarball is a few hundred megabytes. It carries a kubelet, three
control plane binaries, etcd, a Swift runtime, seven Go daemons, the CNI plugins
for two architectures, and a Linux kernel. Nothing is stripped: `strip`
invalidates the ad-hoc signature the Go linker puts on every arm64 binary, and
macOS answers an invalid signature with a bare `Killed: 9`.

**Where things are.**

```
~/.ferry-dist/versions/ferry-<version>/   the release
~/.ferry-dist/current                     -> the one in use
~/.ferry/                                 the cluster: etcd, PKI, kubeconfigs, logs
~/.ferry/logs/service.log                 what the login agent did
~/Library/LaunchAgents/dev.ferry.default.plist
```

A worktree gets its own profile, its own state directory, its own ports and its
own agent; see [PROFILES.md](PROFILES.md). An installed release is always the
`default` profile, since there is one per Mac.
