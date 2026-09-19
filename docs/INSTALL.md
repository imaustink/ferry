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
| `FERRY_RUN` | `/tmp/ferry-run<-profile>` | sockets, pid files, per-run state. Under `/tmp` because macOS caps a unix socket path near 104 bytes |
| `FERRY_PROFILES` | `~/.ferry-profiles` | the register mapping profile names to index numbers |
| `FERRY_NODE_NAME` | `ferry-mac<-profile>` | this node's name |
| `FERRY_LAN_IP` | `en0`, else `en7`, else loopback | the address other Macs reach this one on |

### Pods

| | default | |
|---|---|---|
| `FERRY_POD_CPUS` | `2` | cpus per pod VM |
| `FERRY_POD_MEMORY_MIB` | `512` | memory per pod VM |
| `FERRY_MAX_PODS` | derived from RAM, capped at 110 | how many pods this Mac advertises. An idle pod VM costs ~226 MiB whatever the workload does, so half of memory is budgeted for that |
| `FERRY_EVICTION_DISK` | `4Gi` | free disk below which pods stop scheduling |
| `FERRY_EVICTION_MEMORY` | `500Mi` | free memory below which the kubelet evicts |

### Networking

| | default | |
|---|---|---|
| `FERRY_CLUSTER_CIDR` | `10.244.0.0/16`, or `10.<150+index>.0.0/16` | the pod network every node slices. Empty returns to vmnet addressing and a single node |
| `FERRY_POD_SUBNET` | `192.168.66.1/24` | the vmnet subnet pods get their interface on |
| `FERRY_CLUSTER_DOMAIN` | `cluster.local` | the cluster's DNS domain |
| `FERRY_COREDNS_IMAGE` | `docker.io/coredns/coredns:1.11.3` | the CoreDNS mode 1 runs, and mode 2's machines run |
| `FERRY_NODE_INDEX` | `0` | which `/24` of the cluster CIDR this node owns |
| `FERRY_RELAY_PORT` | `8472` + profile shift | udp port the pod switch uses between Macs |
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
| `FERRY_NODE_VERBOSE` | — | set to print a machine's whole console, kernel included, into `ferry logs ferry-node`. The first thing to reach for when a machine never goes Ready |
| `FERRY_NODE_NO_CONFIG` | — | set to boot a machine without its generated config disk. For debugging the image itself |

### GPU

| | default | |
|---|---|---|
| `FERRY_GPU_CAPACITY` | `1` | how many pods may hold the GPU at once |
| `FERRY_GPU_SLICE` | `0.5` | how long one request holds it before a waiting pod gets a turn |

### Versions and building

| | default | |
|---|---|---|
| `K8S_VERSION` | what is built, else `v1.34.0` | the Kubernetes to build |
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
ports by `control-plane/up.sh`, and `FERRY_ALLOW_OFF_SLICE`,
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
`ferry machines enable` unpacks it to `~/.ferry/node.ext4` (~400 MB, once) using
`ferry-node`'s own unpacker — so Docker is not needed on the installing Mac.
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

A pod picks with a node selector, which is what `kubectl get nodes` already
shows:

```sh
kubectl get nodes -L ferry.dev/mode
```

```yaml
nodeSelector: {ferry.dev/mode: shared}       # dense, one kernel for many pods
nodeSelector: {ferry.dev/mode: vm-per-pod}   # a kernel each
```

The Mac node sets `vm-per-pod` on its own kubelet; `ferry-machined` labels each
machine `shared` once its node registers. Nothing balances between them: the
scheduler places a pod wherever it fits unless the pod says. Provisioning a
machine because a pod needs one, and removing it when it does not, are
MACHINES.md milestones 4 and 5.

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
