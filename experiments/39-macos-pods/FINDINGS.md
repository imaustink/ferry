# macOS pods, in both modes

Every pod ferry runs today is Linux. This asks what a **macOS** pod would be --
a workload that needs Darwin itself: `xcodebuild`, the iOS simulator, codesign,
a macOS-only tool -- in each of ferry's two modes, and measures the parts that
decide it with Virtualization.framework alone.

**Short version.** Mode 1 works and is bounded hard: a macOS pod is a macOS VM
booted from an APFS clone of a golden image, ready in 9-21 s, costing all of
the memory it is given, and **the host runs two at once, full stop**. Mode 2 is
the only way past two. Darwin has no namespaces, but mode 2 can be assembled
from what it does have, and each piece was run: a chroot for a private `/`
(3 ms to start, and only with SIP off in the node VM), a uid per pod, and a
pod's own IP from an address alias, a bind-rewriting dylib and pf rules. Two
pods both binding `:8080` answered this Mac at their own addresses. Put
together as `ferry-darwin`, a CRI runtime under ferry's darwin kubelet in a
macOS guest, that node joined the cluster and ran an ordinary Deployment, Job
and Pod as macOS processes -- Running 3 s after `kubectl apply`, readable with
`kubectl logs`. Declared as a `Machine` with `spec.os: darwin`, it is Ready 10 s
after apply, on ferry's machine network and pod switch, and its pods and the
Mac's Linux pod VMs reach each other at their own addresses.

Run on the M4 Max / macOS 26.6.2 host in the README, with a 26.6.2 guest.

## What was built

| | |
|---|---|
| `macvm.swift` | host tool: `install` an IPSW into a golden bundle, `pod` (clone, boot, run, stop, delete), `ceiling` |
| `agent.swift` | `ferry-macagent`: a LaunchDaemon in the guest, one request per vsock connection -- the stand-in for `vminitd` |
| `inject.sh` | puts the agent on a golden image's Data volume (root, once per image) |
| `seatbelt-run.sh`, `seatbelt-probe.sh` | the rootless shared-kernel container, probed on the host |
| `chroot-probe.sh`, `run-chroot-probe.sh`, `shared-region-why.sh` | the rooted one, probed inside a guest |
| `podexec.c`, `podnet.c`, `podsrv.c`, `netpod-guest.sh`, `run-netpod.sh` | per-pod uid, address and pf on one macOS node |
| `bind-rule-probe.sh` | what a Seatbelt bind rule can name |
| `run-macos-node.sh`, `macos-node-guest.sh` | a macOS guest joined to the cluster as a node |
| `ferry-darwin/` | a CRI runtime for that node: chroot, uid, address, pf per pod |
| `mkimage/`, `darwin-workload.sh` | a darwin OCI image, and ordinary Kubernetes objects run on it |
| `macos-node/`, `bake-macos-node.sh` | the macOS machine image: boot daemon, kubelet config, baked OS base |
| `macos-machine.yaml`, `run-macos-machine.sh`, `cycle-macos-machine.sh`, `machines-on.sh` | a macOS Machine through ferry-machined and ferry-node, and traffic to and from mode 1 |

```sh
./build.sh
curl -fLo .cache/UniversalMac_26.6.2_25G83_Restore.ipsw <url from ipsw.me, VirtualMac2,1>
build/macvm install .cache/UniversalMac_26.6.2_25G83_Restore.ipsw .cache/golden
sudo ./inject.sh .cache/golden
build/macvm pod .cache/golden .cache/pod-a -- /usr/bin/sw_vers
build/macvm ceiling .cache/golden 3
```

## A golden image, with nothing but Apple's framework

| step | |
|---|---|
| restore image | 19.8 GB |
| `VZMacOSInstaller` into a 64 GiB sparse disk | **179 s** |
| golden bundle on disk | 21 GB |
| inject the agent (`sudo`, once) | seconds |

- **Apple's catalog could not be used.** `VZMacOSRestoreImage.fetchLatestSupported`
  failed from this tool ("restore image catalog failed to load"), and the
  catalog it reads now lists only macOS 27 -- newer than the host. The 26.6.2
  IPSW came from ipsw.me's `VirtualMac2,1` list, which marks every build
  unsigned; it installed anyway.
- **A fresh install is usable before anyone sets it up.** The Data volume is
  unencrypted and already populated when the installer finishes, and launchd
  runs `/Library/LaunchDaemons` before Setup Assistant. So the agent answers as
  `uid=0`, `0 users`, on the image's very first boot. No GUI, no account, no SSH.
- **The one privileged step is ownership.** A disk image attached by a user
  mounts with ownership off, and launchd ignores a daemon plist that is not
  `root:wheel`. That is `inject.sh`'s `sudo`, once per golden image.

## Mode 1: the pod is a macOS VM

```
cloned golden bundle in 0.8 ms
pod-a: VM started in 0.22s
pod-a: agent answering                 20.83s
Apple-Virtual-Machine-1.local
exit 0 in 230 ms
pod-a: guest stopped                   stopped in 6.50s
```

| | macOS pod | Linux pod (for scale) |
|---|--:|--:|
| per-pod disk | APFS clone, **0.5-1.5 ms** | ext4 image |
| VM start | 0.17-0.24 s | 0.06-0.09 s |
| ready to run a container | **9.0-20.8 s** (six boots) | 0.33 s |
| run one process | 230 ms | -- |
| stop | 6.1-6.5 s (clean shutdown) | -- |
| host memory, idle, 4 GiB guest | **4.3 GB** | lazily backed |
| concurrent | **2** | 128 |

- **The ceiling is two, it is enforced, and it is its own count.** The third
  guest is refused in 0.15 s: *"The number of virtual machines exceeds the
  limit. The maximum supported number of active virtual machines has been
  reached."* Twelve Linux VMs were running on the host at the time and did not
  count against it. This is the macOS licence's two-VM allowance, implemented
  in the framework; nothing ferry does moves it.
- **A macOS guest touches all of its memory.** 4 GiB configured cost 4.3 GB
  resident while idle, against 1.6 GiB for *128* Linux VMs of 512 MiB. Pod
  memory has to be sized honestly, and it is spent for the pod's life.
- **Ready time is 9-21 s and bimodal.** The golden image itself answered at 8.9
  and 12.7 s; clones at 9.0, 10.2, 10.2, 10.3, 19.9 and 20.8 s with a fresh
  machine identifier each. Two clones *keeping* the golden image's identifier
  ran at once without complaint and answered at 9.7 and 9.9 s. So a shared
  identifier is allowed, and a fresh one is the likely cause of the slow boots
  (six samples; not proven).
- **Shutdown can hang.** With tmpfs and devfs left mounted by a probe, the guest
  ignored `shutdown -h now` and was pulled after 60 s. A runtime needs the
  force-stop fallback `macvm` has.
- **One framework bug to route around.** Closing a vsock connection and
  opening the next from inside the connect callback crashed the host process
  (`objc_release` in `SocketDeviceMessenger::did_open_guest_virtio_socket`).
  Holding the first connection avoids it.

### How it lands in ferry

ferry names its modes as RuntimeClasses -- `ferry-vm` on the Mac, `ferry-shared`
on machines ([RUNTIMES.md](../../docs/RUNTIMES.md)) -- and `ferry-cri` refuses a
sandbox whose handler it does not serve. macOS is two more classes in the same
shape, one per mode:

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata: {name: ferry-macos-vm}
handler: ferry-macos-vm              # served by ferry-cri on the Mac
overhead:
  podFixed:
    memory: 4608Mi                   # the whole guest: a macOS VM touches all of it
    ferry.dev/macos-guest: "1"       # one of the Mac's two macOS guest slots
scheduling:
  nodeSelector: {ferry.dev/mode: vm-per-pod}
  tolerations:
    - {key: ferry.dev/mode, operator: Equal, value: vm-per-pod, effect: NoSchedule}
---
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata: {name: ferry-macos-shared}
handler: ferry-darwin                # served by the darwin runtime in a macOS machine
scheduling:
  nodeSelector: {ferry.dev/mode: shared-macos}
  tolerations:
    - {key: ferry.dev/mode, operator: Equal, value: shared-macos, effect: NoSchedule}
```

*(This was the plan. Mode 1 was ultimately built the other way -- as a macOS
Machine that runs one pod, reusing the mode-2 path with `maxPods: 1` rather than
a `MacPod` inside ferry-cri. See "Mode 1, built" below for what shipped and why.
The design here is kept as the road not taken.)*

**Mode 1, in `ferry-cri`:**

- `RuntimeHandlers.served` gains `ferry-macos-vm`, and `runPodSandbox` branches
  on it: clone the golden bundle, boot it with the pod's interface, and hold a
  `MacPod` where a Linux pod holds a `LinuxPod`. CRI's containers are processes
  the agent starts in that one guest, so a pod's containers share a macOS
  kernel the way a Linux pod's share a Linux one.
- **Containers join a running pod for free.** `PodRootfs` exists because a
  Linux container used to be a disk, and a VM cannot gain one after boot. A
  macOS container is a process, so it never was. What carries over is the
  shape: the base OS is the pod's cloned disk, each distinct workload image is
  attached once read-only, and each container writes to its own scratch.
- **Overhead is the whole guest, and the guest slot rides along.** `ferry-vm`
  charges 133 Mi a pod; a macOS pod VM costs all of its memory, so its
  `podFixed` is the guest size. The API server accepts an extended resource
  there (`overhead-probe.yaml`, `kubectl apply --dry-run=server`), so the class
  can also charge `ferry.dev/macos-guest: 1` against the Mac node advertising
  `2`, and a third macOS pod waits in the scheduler rather than failing at
  `start()`. Validation was checked; the scheduler counting it was not.
- **The agent grows into vminitd's role**: exec, attach, logs, stats, the copy
  RPC `GuestFiles` uses for subPaths and memory-backed emptyDirs, and the pod's
  network configuration -- a macOS guest does not take its address from a
  kernel command line.

**Mode 2, as a Machine:**

- A Machine gains an OS. `ferry-machined` boots the golden image instead of the
  Linux node image, and the guest runs ferry's darwin kubelet -- the one the Mac
  itself runs as a node -- with its own kubelet certificate, as every node now
  has. It registers `ferry.dev/mode=shared-macos` and the matching taint, the
  way machines already register theirs.
- `FerryNodeClass` gains the same field, so Karpenter can make a macOS machine
  for a pending `ferry-macos-shared` pod and take it away when it is empty.
- Neither class can be a `defaultRuntime`: an image is darwin or Linux, so a
  pod that names no class is never a macOS pod. The taint keeps Linux pods off
  macOS machines with no new mechanism.

**Counting, across both:**

- **Memory goes in the ledger as it stands.** A macOS machine counts by
  `spec.memory` like any machine, and the ledger is if anything more honest for
  it: a Linux guest's promise is a ceiling it may never touch, a macOS guest's
  is what it will use.
- **The two guest slots need a ledger of their own.** Mode 1 pods and mode 2
  machines draw on the same two, and today nothing counts them together. The
  memory ledger's pattern fits: `ferry-machined` writes how many macOS machines
  exist, the Mac's kubelet subtracts that from the `ferry.dev/macos-guest` it
  advertises, and Karpenter refuses a macOS machine the slots cannot hold.

**Images:** a macOS "image" is two things -- a base OS (a VM disk, the golden
image) and the workload's own files. Only the second is small. **ferry builds
the base on the user's Mac from Apple's restore image** (as `macvm install`
does, keyed by build), so no macOS image is ever redistributed; **workloads ship
as ordinary OCI layers**; and Tart's OCI images are accepted as an import path
for a base someone already has -- typically one with Xcode in it, which is the
large part.

What it is for: **Jobs, not Deployments.** Two at a time, ten to twenty seconds
to start and gigabytes each is a CI runner, which is what macOS in Kubernetes is
almost always wanted for.

## Mode 2: the node is a macOS VM, pods share its kernel

This is the only way to run more than two macOS pods on one Mac: one of the two
slots holds a node, and the node holds many pods. ferry already builds the
piece that makes the node -- **the kubelet runs on macOS**, it is how the Mac
itself is a node. A macOS `Machine` is that kubelet inside a macOS guest, with
a runtime whose containers are Darwin processes.

What Darwin offers such a runtime is the question, and it is thin. There are no
namespaces -- no mount, network or PID namespace -- and no bind mount (`/sbin`
has `mount_tmpfs` and `mount_devfs`, no nullfs).

### Seatbelt: works, rootless, 15 ms

`seatbelt-run.sh` runs a process under a `(deny default)` profile that allows
the OS read-only and its own root read-write:

```
--- binary from the image:     hello from pid 52896 in .../build/ctr
--- write inside its root:     ok
--- read the user's home:      ls: /Users/...: Operation not permitted
--- write outside its root:    touch: /tmp/ferry-escape: Operation not permitted
--- what it can see:           / holds: home usr bin sbin etc var Library System ...
                               processes visible: 1067
                               interfaces: lo0 ... en0 ... bridge100 vmenet0 ...
--- network:                   200
--- start latency, 20 runs:    15.0 ms per container
```

Kernel-enforced, no root, and fast -- but it confines what a process may
*touch*, not what it can *see*. It lists every process on the machine (1,067,
counted with `sysctl`; `/bin/ps` is setuid and the profile refuses to exec it,
which an earlier reading mistook for isolation), sees the real `/` (an image's
paths live under its root, not at `/`), and shares the node's network stack --
every pod has the node's IP.

### chroot: blocked by the kernel under SIP

Run inside a guest as root, adding one piece of the OS at a time:

| root contains | result |
|---|---|
| only the image's binary | SIGKILL |
| + a copy of `/usr/lib/dyld` | dyld runs, then: `Library not loaded: libSystem.B.dylib (no dyld cache)` |
| + the 6.2 GB shared cache at its cryptex path | same |
| + devfs | same |
| + the cache at `/System/Library/dyld` | **`syscall to map cache into shared region failed`** |

dyld finds the cache and the kernel refuses to map it. The shared region is
keyed by the process's root directory, so a chrooted process gets an empty one
and has to map the cache itself. The sealed snapshot cannot be mounted a second
time either (`mount_apfs: Resource busy`).

### chroot with SIP off: works

Tried on `golden-sipoff`, a clone of the golden image changed in its recoveryOS:

| guest | chroot container |
|---|---|
| SIP on | refused: `syscall to map cache into shared region failed` |
| authenticated root off, SIP otherwise on | **still refused**, same message; the kernel logs no reason |
| **SIP off** (`csrutil disable`) | **runs** |

```
--- this guest: disabled. SIP, authenticated root disabled
--- + the cache at /System/Library/dyld too
    exit 0
    hello from pid 372
      / holds: usr bin System dev tmp
      processes visible: 196
--- a second container sharing the first one's OS files by hard link
    hello from pid 420
--- start, chroot + exec, mean of 10: 2.9 ms
```

- **A container root is `usr/lib/dyld` plus the shared cache at
  `System/Library/dyld`, plus the image.** The cache is 6.2 GB in 31 files and
  took 25-60 s to copy once; every container after that hard-links the same
  files, so a second root costs no new blocks. `DYLD_PRINT_SEGMENTS` shows dyld
  `re-using existing shared cache` for later processes in the same root.
- **Start is 2.9-3.0 ms**, chroot and exec, once a root has mapped its cache.
- **It survives cloning.** A clone given a fresh machine identifier still
  reports SIP disabled and runs the chroot, so the setting travels with the
  golden image and pods do not have to keep its identifier.
- **The narrow change is not enough.** `csrutil authenticated-root disable`
  alone leaves the map refused; only full `csrutil disable` works. And even the
  narrow one tells recoveryOS to *"allow booting unsigned operating systems and
  any kernel extensions"* -- on Apple silicon, both land the guest at the
  permissive boot policy.
- **chroot hides the filesystem and nothing else.** The chrooted process still
  counts every process on the node and sees every interface. It is the
  filesystem piece of mode 2, to be combined with the uid, address and pf
  pieces below -- not a boundary on its own, since root escapes a chroot.
- **Memory is not measured.** Hard-linked roots share inodes and so page
  cache, but whether each root's shared region costs its own page tables is
  open.

**Getting a golden image to SIP off** is a one-time manual step in the guest's
recoveryOS, and it took four tries to learn:

1. recoveryOS will only authorise an admin it can see on the Preboot volume. An
   account made by `sysadminctl` through the agent gets a secure token and is
   volume owner, and recovery still said *"no admin users authorized for
   recovery"* -- until `diskutil apfs updatePreboot /` ran, after which it was
   accepted.
2. The recovery boot picker shows the disk beside **Options**; picking the disk
   boots normal macOS.
3. `csrutil disable` must be followed by `halt` inside the guest. Stopping the
   VM from the host first discards the change.

`macvm boot <bundle> --recovery` opens the window for it.

### Images cannot carry Apple's binaries

A copy of `/bin/echo` placed in a container root is killed with SIGKILL before
it runs, on this Mac with SIP on. A platform binary is trusted where the OS
put it and nowhere else. So a Darwin image is the author's own binaries plus
whatever it links from the OS it lands on -- the base layer is always the node,
the way process-isolated Windows containers depend on their host's build.
(On a node with SIP off a copy does run, which is how pods later get a shell:
the node supplies the OS's tools. See "kubectl exec, port-forward, probes".)

### What mode 2 on macOS would be

| | Linux machine | macOS machine |
|---|---|---|
| node | Linux VM, containerd | macOS VM, ferry's darwin kubelet |
| container | namespaces + cgroups | chroot (SIP off in the node) or Seatbelt, + a uid per pod |
| pod IP | its own | its own: alias + bind shim + pf (above) |
| machines per Mac | many | **two**, and each costs its full memory |
| container start | ~45 ms | 3 ms (chroot), 15 ms (Seatbelt); 3-4 s the first time a new binary runs |

### Per-pod addresses, without a network namespace

Without namespaces every pod on a macOS node would share one address -- two
pods could not both listen on :8080, and a Service would have nowhere
pod-specific to send traffic. Seatbelt cannot fix that: a `network-bind` rule
takes only `*` or `localhost` (`host must be * or localhost in network
address`), so it can forbid binding but not pin a pod to an address.

What does work is three pieces together (`podexec.c`, `podnet.c`,
`netpod-guest.sh`, driven by `run-netpod.sh`):

| piece | what it does |
|---|---|
| alias on `en0` + host route via `lo0` | the pod's address: the Mac reaches it by ARP, the node reaches it by loopback |
| `podnet.dylib` (`DYLD_INSERT_LIBRARIES`) | `bind(0.0.0.0)` and `bind([::])` become the pod's address; an unbound `connect` is bound to it first |
| a uid per pod | pods cannot signal or read each other |
| pf `user` rules | an address accepts and emits traffic only for its own pod's sockets |

Three pods on one macOS node, the workload binding the wildcard as ordinary
servers do:

```
pod-a asked for 0.0.0.0, is bound to 192.168.64.231:8080
pod-b asked for [::],    is bound to [::ffff:192.168.64.232]:8080
rogue asked for 192.168.64.231, is bound to 192.168.64.231:8081

=== from this Mac
192.168.64.231:8080   pod-a (uid 601) sees peer 192.168.64.1
192.168.64.232:8080   pod-b (uid 602) sees peer ::ffff:192.168.64.1
192.168.64.16:8080    Connection refused      (the node's own address: nobody has the wildcard)
192.168.64.231:8081   Connection refused      (the rogue, blocked by pf)

=== inside the node
pod-a -> pod-b        pod-b sees peer ::ffff:192.168.64.231   (pod-a's address, not the node's)
rogue, pf off         reachable -- so it is pf that refuses it, not a failed bind
pod-a signals pod-b   Operation not permitted
pod-a reads pod-b     Operation not permitted
```

Two pods on :8080, each at its own address, calling each other from their own
addresses: the Kubernetes network model, on a kernel with no network
namespaces.

What it costs and where it stops:

- **The shim is a convenience, pf is the boundary.** A process that makes the
  syscall directly, or a binary with the hardened runtime (which ignores
  `DYLD_INSERT_LIBRARIES` without an entitlement), skips the rewrite. It then
  binds the wildcard or leaves from the node's address -- and pf's `user` rules
  still stop it using another pod's address. Go on darwin calls libSystem, so
  Go binaries get the rewrite.
- **Wildcard binds are exclusive.** A pod that escapes the rewrite and binds
  `0.0.0.0:8080` takes that port from every pod on the node. pf could block
  wildcard listeners outright; not tried.
- **UDP `sendto` on an unbound socket** is not rewritten, so it leaves from the
  node's address. One more interposed call.
- **First launch of a new binary is slow.** The pods took 3-4 s to reach
  `bind` on first run, which looks like the guest's code-signing assessment
  of an unfamiliar ad-hoc binary. Later launches of the same binary in the
  same run came back at once; not timed.
- **The addresses here are aliases on a NAT network.** In ferry the node's pod
  CIDR slice is routed to it, so the addresses could live on `lo0` alone.

### A macOS machine joins the cluster as a node

`run-macos-node.sh` boots a clone of `golden-sipoff` with a read-only virtiofs
share (`macvm --share`), puts ferry's darwin kubelet and a CRI runtime in it,
and joins it to this checkout's ferry cluster the way `ferry-machined` joins a
Linux machine: a bootstrap token in `system:bootstrappers:ferry:default-node-token`,
the same three ClusterRoleBindings, and the kubelet asks for its own
certificate. The kubelet config is the Mac node's own, moved to the guest's
paths. The runtime here is experiment 01's `fakecri`, which answers every CRI
call without running anything -- this step asks whether the node side works,
not the containers.

```
=== macos-node-0 Ready 1 s after the kubelet started
NAME                         STATUS  VERSION  INTERNAL-IP    OS-IMAGE      CONTAINER-RUNTIME          MODE
ferry-mac-macos-containers   Ready   v1.37.0  192.168.1.29   macOS 26.6.2  ferry://0.10.0-2-g801d6b1  vm-per-pod
macos-node-0                 Ready   v1.37.0  192.168.64.38  macOS 26.6.2  ferry-fakecri://0.1.0      shared-macos
    os/arch: darwin/arm64   capacity: {"cpu":"4","ephemeral-storage":"59916Mi","memory":"4Gi","pods":"110"}
    taints: [{"effect":"NoSchedule","key":"ferry.dev/mode","value":"shared-macos"}]
    node-csr-...   kubernetes.io/kube-apiserver-client-kubelet   system:bootstrap:c90677   Approved,Issued

--- a ferry-macos-shared pod
hello-macos   1/1   Running   macos-node-0
    Scheduled   Successfully assigned default/hello-macos to macos-node-0
    Pulled, Created, Started
```

- **ferry's darwin kubelet runs unmodified in a guest.** The ~450 lines that
  make the Mac a node make any macOS a node: node Ready one second after the
  kubelet started, its client certificate issued through the bootstrap flow
  every ferry node now uses, and the label and taint registered by the kubelet
  itself.
- **The RuntimeClass shape works end to end.** A pod naming
  `ferry-macos-shared` had the class's selector and toleration merged in, was
  scheduled only onto the macOS node, and ran through a full CRI lifecycle
  there -- sandbox, pull, create, start, then stop on delete.
- **A RuntimeClass handler cannot be empty** (`handler: Required value`), so
  the class needs a real name; `ferry-darwin` here.
- **The guest reports its NAT address** (192.168.64.x). A real macOS machine
  would be on ferry's pod network like a Linux one, and its pod CIDR slice
  routed to it.
- **Same eviction gap as the Mac node**: `allocatableMemory.available` cannot be
  built without a `pods` cgroup, and the kubelet logs it every ten seconds.
- **Two things that cost time, worth keeping:** the kubelet's `--root-dir` and
  its binary cannot share a name in one directory; and a host script that fails
  after booting a guest must still release it, or the guest holds one of the
  Mac's two macOS slots until it times out. `run-macos-node.sh` now touches
  `done` on any exit.

### ferry-darwin: real pods on the macOS node

`ferry-darwin/` is a CRI runtime for a macOS node, grown from `fakecri`: every
call that was a record there does the work here, combining the pieces above
in one pod.

| CRI | on the macOS node |
|---|---|
| `PullImage` | `ferry-registry`'s mirror protocol (`/v2/<repo>/manifests/<tag>?ns=<host>`); darwin/arm64 only; layers unpacked into the image store |
| `RunPodSandbox` | an address (alias on `en0` + host route via `lo0`), a uid, pf `user` rules in a `ferry` anchor; refuses any handler but `ferry-darwin` |
| `CreateContainer` | a root of hard links: dyld and the shared cache from the node (copied once), the image's files, `podnet.dylib`; its own `/tmp` |
| `StartContainer` | `SysProcAttr{Chroot, Credential, Setpgid}`, `/dev` from `mount_devfs`, output in the CRI log format at the kubelet's path |
| `StopContainer` | SIGTERM to the process group, SIGKILL after the grace period |

Images are built by `mkimage/` -- a directory as a one-layer darwin/arm64 OCI
layout -- and added with `ferry-registry add`. The guest reaches a second
read-only `ferry-registry serve` on the same store, allowed its NAT subnet;
a real macOS machine would be on the machine network the registry already
serves.

`darwin-workload.sh` is ordinary Kubernetes, nothing macOS-specific but the
RuntimeClass and the image:

```
macos-node-0   Ready   192.168.64.41   macOS 26.6.2   ferry-darwin://0.1.0   shared-macos
    handlers: ferry-darwin
image: pulled example.com/podsrv-darwin:1 (sha256:6da0cbfaa92b, 4072 bytes) in 15ms
two web replicas Running and the Job finished 3 s after apply

hello-nhzq4            Completed   192.168.64.201   macos-node-0
web-798c844958-d5pll   Running     192.168.64.200   macos-node-0
web-798c844958-jqcvz   Running     192.168.64.202   macos-node-0

--- kubectl logs job/hello
    / holds: usr bin System lib dev tmp
--- kubectl logs, each web replica
    web asked for 0.0.0.0, is bound to 192.168.64.200:8080
    web asked for 0.0.0.0, is bound to 192.168.64.202:8080
--- from this Mac, each replica at its own address
    192.168.64.200:8080  web (uid 1001) sees peer 192.168.64.1
    192.168.64.202:8080  web (uid 1003) sees peer 192.168.64.1
    192.168.64.41:8080 (the node)  Connection refused
--- a caller pod, calling 192.168.64.200
    caller: web (uid 1001) sees peer 192.168.64.203     (the caller's own address)
```

- **A Deployment, a Job and a Pod ran as macOS processes sharing one XNU
  kernel**, each with a private `/`, its own uid and its own address, and
  `kubectl logs` read them. Two replicas of a server that binds the wildcard
  sat side by side on :8080.
- **It is fast once the node is up.** Created to started in 8 ms, `hello` ran
  in 155 ms, and a replica set of two plus a Job reached Running and Completed
  3 s after `kubectl apply`. The image pull was 15 ms for a 4 KB layer.
- **The node pays once, at start.** Copying dyld and the 6.2 GB shared cache
  took 27-35 s before the runtime served. That belongs in the golden image,
  where it would cost nothing per boot.
- **The kubelet exits if its runtime is not serving when it starts**, so the
  node's start order is runtime, then kubelet -- as `ferry up` already does on
  the Mac.
- **The 3-4 s first launch seen earlier did not appear.** That run went through
  `podexec`'s Seatbelt profile; this one did not. The likelier cause is the
  profile, not a new binary's first launch -- not isolated.
- **Stop is SIGTERM to the process group.** `podsrv` does not handle it, so the
  replicas exited 143 and read `Error` for the moment before they were gone.
- **One kubelet error is new and harmless**: it cannot make the legacy
  `/var/log/containers` symlink, which the guest does not have.

What it does not do yet: `attach`; container stats; resource limits (there are
no cgroups); and state that survives a runtime restart. Cluster DNS, Services,
exec, port-forward, volumes and egress came later -- see the sections that
follow.

### A macOS Machine, on ferry's networks

The same node, made the way ferry makes a Linux machine -- `kubectl apply` a
`Machine` -- and on the same two networks:

```yaml
apiVersion: ferry.dev/v1alpha1
kind: Machine
metadata: {name: mac-0}
spec: {os: darwin, cpus: 4, memory: 4Gi}
```

```
=== kubectl apply a Machine, spec.os: darwin
    mac-0 Ready 10 s after apply
    mac-0   Running   192.168.240.2   mac-0
    mac-0   Ready   192.168.240.2   macOS 26.6.2   ferry-darwin://0.1.0   shared-macos
    podCIDR: 10.190.4.0/24   handlers: ferry-darwin
    taints: [{"effect":"NoSchedule","key":"ferry.dev/mode","value":"shared-macos"}]
=== darwin pods on the machine
    web x2 and linux-listener Running 2 s after apply
    linux-listener         10.190.0.3   ferry-mac-macos-containers     (a Linux pod VM, ferry-vm)
    web-798c844958-hz7t8   10.190.4.2   mac-0
    web-798c844958-t6g98   10.190.4.3   mac-0
    web asked for 0.0.0.0, is bound to 10.190.4.2:8080
=== a Linux pod VM on the Mac calls a macOS pod (10.190.4.2:8080)
    linux-caller: web (uid 1001) sees peer 10.190.0.4
=== a macOS pod calls the Linux pod VM (10.190.0.3:9000)
    mac-caller: hello-from-a-linux-pod-vm
```

A macOS pod and a Linux pod VM, each at its own address on ferry's pod
network, reaching each other both ways -- the cluster's one flat network,
now with a third kind of pod on it. `kubectl delete machine` removed the Node,
the bundle and its token.

What it took, outside this directory:

| where | change |
|---|---|
| `ferry-machined` | `spec.os: darwin`: clone `--mac-image` (a bundle directory) instead of the node disk; label `ferry.dev/mode=shared-macos`; always register and keep the taint, whatever `defaultRuntime` is; remove the config share with the machine |
| `ferry-machined/crd.yaml` | `spec.os`, enum `linux`, `darwin` |
| `ferry-node` (`MacMachine.swift`) | a darwin spec boots the bundle with `VZMacOSBootLoader`, the same two cards a Linux machine has, a read-only `ferry-config` share in place of the kernel command line, and a writable `ferry-logs` share in place of a console |
| `ferry` | `FERRY_MAC_IMAGE` passed on as `--mac-image`, and only when set |

And in the golden image, baked by `bake-macos-node.sh` from `golden-sipoff`:
`ferry-macos-init` as a LaunchDaemon -- the counterpart of the node image's
`init.sh` -- with the kubelet, `ferry-darwin`, the shim, and the OS base
already copied, so a machine does not spend 27-36 s on it at boot.

- **10 s from `kubectl apply` to a Ready macOS node**, and 2 s from a
  Deployment's apply to its pods Running. The README gives 16 s for a Linux machine.
- **The pod network needed nothing new.** A Linux machine puts its slice's .1
  on eth1 with the cluster prefix and proxy-ARPs for its pods. A macOS
  machine puts the same address on its pod card, and each pod's address is an
  alias on that card, which answers ARP for itself -- so a pod VM on the Mac
  that treats the cluster CIDR as on-link finds a macOS pod exactly as it
  finds a Linux one. No route agent.
- **`ferry-darwin` takes the pod CIDR from the kubelet.** `UpdateRuntimeConfig`
  carries the slice kube-controller-manager chose, and the runtime reports
  `NetworkReady=false` until it has one, which is the signal a Linux node's
  missing CNI config gives.
- **Pulls go through the machine registry as they do on a Linux machine** --
  `ferry-registry` at the gateway, which already answers the machine subnet.
  The workaround instance of the earlier step is not needed here.
- **The default-runtime reconciler would have untainted it.** It makes every
  `ferry.dev/mode` taint match the cluster's default, and under a default of
  none it removes them -- which, on a macOS machine, would let any Linux pod
  that names no RuntimeClass land on XNU. It now keeps a `shared-macos` taint
  under every policy (`TestMacOSMachineKeepsItsTaint`).

Two things that cost a boot each, both now handled:

- **A macOS guest does not name interfaces in attach order.** It already has
  an `en1` before either card is attached, so the pod card was `en2`.
  ferry-node gives each card a MAC address and writes it into the config
  share; the guest finds its cards by MAC.
- **`ipconfig set <if> MANUAL` is asynchronous.** The default route added right
  after it was refused (`Network is unreachable`), leaving a node that answered
  ping on its segment and could not reach the API server off it. The boot now
  waits for the address before adding the route.

Not done at this point, and done below: Karpenter did not make macOS machines,
and a third macOS machine failed at start with the framework's own message
rather than waiting. See "macOS machines on demand". Services are the next
section.

### Services and cluster DNS

Two Services, one backed by the macOS replicas and one by a Linux pod VM on
the Mac, each called four times by name from both kinds of pod:

```
web-svc     ClusterIP   10.96.224.49   80/TCP     -> 10.190.11.2:8080, 10.190.11.3:8080   (macOS)
linux-svc   ClusterIP   10.96.85.135   9000/TCP   -> 10.190.0.29:9000                     (Linux pod VM)

--- a Linux pod VM calls web-svc (macOS endpoints) by name
    web (uid 1001), web (uid 1001), web (uid 1002), web (uid 1001)
--- a macOS pod calls web-svc.default.svc.cluster.local:80 by name
    web-svc.default.svc.cluster.local is 10.96.224.49
    web (uid 1002) sees peer 10.190.11.5
    web (uid 1001) sees peer 10.190.11.5
    web (uid 1002) ...  web (uid 1001) ...
--- a macOS pod calls linux-svc.default.svc.cluster.local:9000 by name
    linux-svc.default.svc.cluster.local is 10.96.85.135
    hello-from-a-linux-pod-vm  (x4)
```

**Into macOS pods, nothing was needed.** A Linux pod VM applies kube-proxy's
rules in its own kernel, and they DNAT a ClusterIP to endpoint pod addresses
-- which for `web-svc` are macOS pods, already reachable on the pod switch.

**Out of macOS pods, the shim is kube-proxy.** There are no kernel rules to
program on a macOS node, and pf's `rdr` does not see traffic a local process
originates. But `podnet.dylib` is already in every container's `connect()`, so
the rewrite happens there, per socket, as Cilium's socket-level load
balancer does it: `ferry-darwin` polls Services and EndpointSlices with the
kubelet's own certificate (`system:node` may list both), writes one line per
service port into `/lib/ferry-services` in every container root, and the shim
sends a connect to a ClusterIP to one of its endpoints at random.

**Cluster DNS is the node's resolver, pointed at CoreDNS.** A pod's
resolv.conf means nothing on macOS: names go to mDNSResponder, one per node.
`ferry-darwin` writes `/etc/resolver/cluster.local` naming the endpoints of
the cluster DNS Service -- endpoints, not the ClusterIP, which mDNSResponder
would send to without the shim -- or, with none, ferry's reserved CoreDNS
address, `.0.2` of the cluster CIDR. Three things had to be true, each found
by a pod that failed:

1. **The resolver socket has to be in the root.** libSystem reaches
   mDNSResponder over `/var/run/mDNSResponder`, which a chroot does not have.
   A hard link to a UNIX socket is the socket, so each root gets one.
2. **configd has to think the resolvers are reachable.** With the machine
   card given an address by `ipconfig set MANUAL` -- an address and no router
   -- `scutil --dns` listed every resolver `Not Reachable`, and `getaddrinfo`
   skips those. `dscacheutil` does not, which is why the node itself resolved
   `kubernetes.default` while pods, and the same probe run as the node, did
   not. `ferry-macos-init` now configures the card as a network service with
   `networksetup -setmanual <service> <ip> <mask> <router>`, and 1.1.1.1 as its
   DNS server -- what a Linux machine gets.
3. **The shim a pod gets has to be the current one.** The runtime copied it
   into the OS base only with the 6 GB cache, so an image updated in place kept
   the shim it was first baked with, and ClusterIP connects went out unrewritten.
   It is now copied on every start -- to a new file renamed into place, since
   the old one is hard-linked into running pods' roots and truncating it would
   rewrite a library under them.

The debugging that found these is kept as three pod annotations on
`ferry-darwin` -- `ferry.dev/debug-root`, `ferry.dev/debug-no-chroot` and
`ferry.dev/debug-host`, the last running a pod's command as the node itself --
and `dns-probe*.yaml`, `services-probe.yaml`, `run-dns-probe.sh`. Each takes an
isolation away; they are for finding which piece a failure comes from.

What it does not do: NodePorts and LoadBalancers aimed at macOS pods from outside;
headless Services beyond what DNS already answers; session affinity; and a
pod's short names -- `web-svc` rather than the full name -- since the search
list is the node's, not the pod's. A process that makes the syscall directly,
or a hardened-runtime binary that ignores `DYLD_INSERT_LIBRARIES`, reaches
neither the address rewrite nor Services.

### kubectl exec, port-forward, probes -- and a shell

`ferry-darwin` embeds the streaming server `ferry-streamer` runs for the Mac's
pod VMs (`k8s.io/kubelet/pkg/cri/streaming`); the runtime is Go here, so there
is no bridge to cross. `run-macos-exec.sh`:

```
=== web is True Ready, through an exec readinessProbe
=== kubectl exec web -- /bin/hello probe
    hello from pid 541
      / holds: usr bin var System lib dev tmp
=== the exit code comes back: kubectl exec web -- /bin/podsrv get 127.0.0.1 1
    connect: Connection refused
    command terminated with exit code 1
    kubectl exited 1
=== stdin: echo ... | kubectl exec -i web -- /bin/podsrv echo
    pid 544, uid 1006 read: hello through stdin
=== kubectl port-forward pod/web 18080:8080
    web (uid 1006) sees peer 10.190.14.1
=== a shell in a macOS pod: the node's /bin and /usr/bin, in every root
    sh, pid 547, uid 1006, Darwin 25.6.0
    /bin: 39 tools, /usr/bin: 924
    zsh 5.9 on a tty: /dev/ttys000
    -r-x--x--x  /usr/bin/sudo -- not setuid in a pod root
=== a pod written the Linux way: command: [/bin/sh, -c, ...]
    step 1 on macOS 26.6.2
```

- **exec is another process of the container** -- its root, its uid, its
  environment and the shim -- as a Linux runtime's exec joins the container's
  namespaces. `-t` gets a pseudo-terminal (`creack/pty`, as the controlling
  terminal, on top of the chroot and the uid); exit codes come back through
  the full `ExitError` interface, which ferry-streamer found the server needs.
  `ExecSync` runs exec probes the same way.
- **port-forward dials from the node's own pod-network address.** The first
  try timed out: connecting to one of its own aliases, the kernel picked the
  pod's address as the source, and pf refused it -- that address carries
  traffic only for the pod's uid, and the runtime is root.
- **Attach is built too** (see below): `kubectl attach`, stdin, and a terminal.

**macOS pods have a shell.** An image still cannot carry Apple's binaries --
on a Mac with SIP on, a copy is killed before it runs -- but on a node with
SIP off a copy runs. So the node provides them the way it provides libSystem:
`/bin`, `/usr/bin` (4 + 80 MB on macOS 26), `/usr/share/terminfo` and
`SystemVersion.plist` are copied into the OS base once per image and
hard-linked into every root, with the image's own files winning where names
meet. That makes a macOS pod usable the way a Linux one is -- `kubectl exec -it
pod -- zsh`, `command: [/bin/sh, -c, ...]` -- and it cost two things to find:

- **The shim has to be arm64e too.** Apple's binaries are arm64e, and dyld
  aborts an arm64e process rather than insert an arm64 library into it --
  every tool died with `incompatible architecture (have 'arm64', need
  'arm64e')`. `podnet.dylib` is now built with both slices, and dyld inserts
  the arm64e one into Apple's tools without complaint on this SIP-off node.
- **`kubectl exec -t` is dropped** unless kubectl's own stdin is a terminal,
  so a scripted test of `-t` tests nothing; `script(1)` gives it one.

Tools are copied with their permission bits only, so `sudo`, `su` and the
rest are not setuid in a pod root. `/sbin` and `/usr/sbin` were added for the
macOS-VM pods below -- `sysctl`, `ifconfig`, `mount` -- and the pod's `PATH`
and argv[0] lookup are macOS's own (`/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`)
so a tool is found where a Mac's shell finds it. What a pod does not get is the
OS's `/etc` -- no passwd entries for pod uids, so `id -un` has no name -- nor
`/usr/libexec` or `/Applications`; Xcode would be a mount or an image of its
own.

### kubectl attach, stdin and a terminal

`run-macos-attach.sh`, four cases:

```
=== kubectl attach ticker, for four seconds
    tick 1
    tick 2
    tick 3
=== echo ... | kubectl attach -i catter   (stdin, stdinOnce)
    catter: Succeeded, log: hello through attach
=== kubectl attach -it termy   (a terminal)
    shell on /dev/ttys000, 40 80 rows/cols
=== kubectl run -i --rm   (attach underneath)
    run -i read: a line for run, on macOS 26.6.2
```

A container's output used to go one way, into its log. For attach it has to
reach whoever is attached as well, as it arrives, so each container's output
is read in chunks: the chunk fans out to every attached client and its lines
go to the log in the kubelet's format. `stdin: true` gives the container a pipe
attach writes into, closed after the first client when it asked `stdinOnce`;
`tty: true` runs it on a pseudo-terminal attach reads, writes and resizes.
`kubectl run -i --rm` and `kubectl exec -i` are the same fan-out and pipe. Input
typed before attach has the terminal in raw mode is lost to the shell's line
editor, as it would be typing ahead of a prompt at a real keyboard, so the test
types after a pause.

### PersistentVolumes, shared with Linux pods

`run-macos-pvc.sh` -- a claim written by a macOS pod, read after it is gone by a
second macOS pod, then by a Linux pod VM, then on the Mac itself:

```
=== a macOS pod writes to the claim
    pv-writer: Succeeded on mac-0
    written on macOS 26.6.2 by uid 1006
    claim bound to pvc-af8b7dd2-..., a hostPath at ~/.ferry-.../volumes/pvc-af8b7dd2-...
=== a second macOS pod, after the first is gone
    written on macOS 26.6.2 by uid 1006
=== a Linux pod VM on the Mac, the same claim
    read on Linux 6.18.5-ferry:
    written on macOS 26.6.2 by uid 1006
    and on the Mac itself: written on macOS 26.6.2 by uid 1006
```

ferry-storage makes a PersistentVolume a directory on the Mac, and ferry-node
shares the Mac's whole volumes directory into the machine over virtiofs at the
same path. The kernel's `nfsd` mounts a node-disk directory into a container
root (above), but **it would not export a directory on a virtiofs mount** -- it
left the share out of its exports and said nothing, the way it does for a
filesystem it does not like. So each PersistentVolume a container mounts gets a
**userspace NFS server of its own** (`go-nfs`) on a loopback port, rooted at
that volume's directory -- bound, so a symlink cannot lead out of it -- and the
container root mounts that. A pod sees its own claim and nothing else of the
share, which one mount of the whole share would not give. The same directory is
the Mac's, a Linux pod VM's `hostPath` mount, and a macOS pod's NFS mount at
once, so a claim moves between all three kinds of pod.

That userspace server had to be shut to other pods; the reserved-port finding
below is what closed it.

### Container CPU and memory, without cgroups

`run-macos-stats.sh` -- a pod that holds ~40 MB and spins a core, read through
the kubelet's summary API (what `kubectl top` and metrics-server read):

```
=== container stats for pod busy, from the summary API
    t0: busy cpu_ns=1270214    mem_bytes=4148032
    t1: busy cpu_ns=216357274  mem_bytes=83690560
    verdict: ok: CPU rose 215 ms over 10 s, memory 79 MiB
```

The stats CRI calls used to return empty -- "there is no per-pod accounting
without cgroups." There is, without them: a container is a **process group**
(StartContainer sets `Setpgid`, so the group's id is the container's pid), so
`ContainerStats` sums the group. `proc_listpids(PROC_PGRP_ONLY, pgid)` lists its
processes and `proc_pid_rusage` reads each (cgo, `libproc`): `ri_user_time +
ri_system_time` is cumulative CPU in nanoseconds -- exactly the counter
`UsageCoreNanoSeconds` wants, which the kubelet differences into a rate --
and `ri_phys_footprint` is the memory Activity Monitor shows, the closest macOS
has to a working set. `ListContainerStats`, `PodSandboxStats` and
`ListPodSandboxStats` are the same, the pod's numbers its containers' summed
(there is no pod process to measure, only its containers'). This is the first
cgo in the runtime, so `ferry-darwin` is now built with `CGO_ENABLED=1` -- the
default when building on the Mac for the Mac, which the bake already does.

### macOS machines on demand

Nothing declared: a Deployment of `ferry-macos-shared` pods, and Karpenter
makes the macOS machines it needs and takes them away (`run-macos-autoscale.sh`):

```
=== 1. one replica, no machines: kubectl apply at 0 s
    Running after 17 s
    macos-ctdxt   ferry-macos-4cpu-4gi   Running   192.168.240.2
=== 2. three replicas that each need a machine of their own (6 GiB each)
    macos-ctdxt   ferry-macos-4cpu-4gi
    macos-tng77   ferry-macos-4cpu-8gi
    auto-67986b4fd8-4chmd   Running   macos-tng77
    auto-67986b4fd8-ldsb5   Pending
      FailedScheduling   Failed to schedule pod, nodepool requirements filtered
                         out all available instance types
=== 3. zero replicas: the machines go
    no machines after 109 s
```

- **17 s from `kubectl apply` to a Running macOS pod on a machine that did not
  exist**: Karpenter's decision, the clone, the boot, the join and the pod.
- **The third macOS machine is never attempted.** Two macOS guests fill the
  Mac, and a third VM would be refused at start. `ferry-karpenter` offers macOS
  shapes only while a slot is free -- the count of `spec.os: darwin`
  Machines, under the same lock as the memory budget -- so the pod waits in
  the scheduler and a VM that could not boot is never made.
- **Consolidation returns the memory.** An empty macOS machine is taken away
  60 s after it empties (`WhenEmpty`), which matters more for macOS than for
  Linux: it holds all its memory and one of two slots for as long as it lives.

What it took:

| where | change |
|---|---|
| `ferry-karpenter` | a second family of instance types, `ferry-macos-<c>cpu-<m>gi` (4/4, 4/8, 8/16, capped by the per-machine maximum), with `kubernetes.io/os=darwin` and `ferry.dev/mode=shared-macos`; available only while a macOS slot is free; `Create` writes `spec.os: darwin` and no Linux image; drift ignores the image for macOS machines; a larger reserve for the guest OS (1.5 GiB, not measured) |
| `manifests/machines/karpenter/macos-nodepool.yaml` | a `macos` NodePool: template label `shared-macos`, requirement `os In [darwin]`, the taint, `WhenEmpty` |
| `ferry` | applies that pool only when `FERRY_MAC_IMAGE` is set, and removes it otherwise |

Tests: `ferry-karpenter/macos_test.go` -- macOS names round-trip to macOS
shapes; instance types say their OS and mode; two macOS Machines make every
macOS type unavailable and leave Linux types alone, and a third `Create` is an
`InsufficientCapacityError`; a macOS machine gets no Linux image and does not
drift. Writing that last one found a bug in `Create` that had nothing to do with
macOS: it put a `[]string` into an unstructured object, whose content must be
JSON-shaped, and the fake client's deep copy panicked on it. The real client
had been serialising it anyway; it is `[]any` now.

What the Pending pod's message does not say is *why* the instance types were
filtered: Karpenter reports "filtered out all available instance types" for a
full macOS slot count the same way it would for an exhausted memory budget.
The reason is in ferry-karpenter's own words only when `Create` itself refuses.

### Volumes, and the way off the cluster

`run-macos-volumes.sh`, one pod and a Job, all eight checks passing:

```
=== ConfigMap, Secret
    hello from a ConfigMap
    hunter2, from a Secret
=== the emptyDir, written by one container and read by another
    tick 4 from the writer, uid 1006
=== the pod's own ServiceAccount token, against the API server
    token: 1142 bytes
    GET own pod with it: HTTP 403            (authenticated; the default SA may not read pods)
      "gitVersion": "v1.37.0",
=== off the cluster: the internet, from the node's address
    https://example.com: HTTP 200
=== /etc/hosts, from the kubelet                (10.190.25.7  vols)
=== a read-only volume refuses a write
    /bin/sh: /config/new: Read-only file system
=== a ConfigMap update reaches the running pod
    after 87 s: hello again, updated         (the kubelet's own sync period)
=== a termination message
    exit 3, message: the last thing this container said
```

**Volumes are loopback NFS.** macOS has no bind mount, no nullfs; a symlink
resolves inside the chroot and a directory cannot be hard-linked. It does ship
`nfsd`. So `ferry-darwin` exports the kubelet's `pods/` directory to 127.0.0.1
once, and NFS-mounts each directory volume into the container root: a
loopback mount is a bind mount by another name. It mounts in 0.1 s, can be
mounted at several paths -- which is what two containers sharing an emptyDir
need -- and needs nothing of SIP. `nfs-probe.yaml` checked the primitive before
anything was built on it.

- **`-mapall=root`**, because a pod's uid has no user record and the kubelet
  writes what it projects as root: a ServiceAccount token is 0600 root, and a
  pod could not otherwise read its own. The mounts are `nosuid,nodev`, so a
  volume the pod can write as root is not a way to plant a setuid binary; a
  pod's uid cannot mount anything, so it only ever has the volumes it was
  given.
- **File mounts are hard links** -- `/etc/hosts`, and `/dev/termination-log`,
  which took three tries:
  1. devfs over `/dev` hid the hard link, and devfs holds no regular files;
  2. an ordinary `/dev` of `mknod`'ed nodes would have held it, but
     `mount_fdesc` refuses a mount point that is not devfs, and a `/dev` with no
     `/dev/fd` or `/dev/stderr` breaks half the shell scripts there are;
  3. devfs does take a *symlink* (`devfs-probe.yaml`), so the file is linked at
     `/.ferry/dev/termination-log` in the root and `/dev/termination-log` points
     at it -- and the kubelet then still read nothing, because it finds the file
     through the `Mounts` in the runtime's `ContainerStatus`, which were not
     being returned. With both, a Job's message comes back.
- **Mounts go before the root does.** Removing a root through a live mount
  would delete the volume's contents on the node, so `RemoveContainer`
  unmounts first and then refuses to remove a root the mount table still
  shows. After the kubelet's container GC, the node held no mounts but the
  running probe's (`mounts-probe.yaml`).
- **nfsd is slow to first export.** `nfsd restart` took exactly 20 s, a
  timeout; `nfsd start` returns in 15 ms but the export appears 10.5 s later
  with `127.0.0.1` in `/etc/exports` (20 s with `localhost`, which mountd
  resolves). So nfsd comes up beside the runtime rather than before it: the
  node is Ready in 12-16 s, and only a container with a directory volume waits.

**Egress was broken for every macOS pod until this test.** The shim bound every
outbound connection to the pod's address, and the machine network's NAT only
knows the machine subnet -- so nothing off the cluster answered: not the
internet, and not the API server's LAN address that `kubernetes.default`
resolves to. The Service and DNS tests had only ever reached pods. The shim now
binds to the pod's address only for destinations in the cluster CIDR
(`FERRY_CLUSTER_CIDR`) and lets everything else leave from the node's, which is
what a Linux node's masquerade does. `/private/etc/ssl` joined the OS base, and
`/etc` a link to `/private/etc`, for curl's CA bundle.

**`/dev` is the node's devfs, with fdesc over it** for `/dev/fd` and
`/dev/std{in,out,err}`. That means a pod sees every device node the node has --
`disk*`, `rdisk*`, `bpf*`, `pf`, `dtrace`, `console`. They are root-only and a
pod's processes are not root, which is what keeps it out; macOS's devfs has no
per-mount rules to hide them the way FreeBSD's `devfs.rules` would.

**nfsd takes requests only from reserved ports**, or a pod could read every
pod's volumes. The exports go to 127.0.0.1 with `-mapall=root`, and a pod's
processes are on 127.0.0.1 too -- so an ordinary pod could speak NFS from
userspace to `nfsd` and to the per-PV servers and read another pod's Secrets,
tokens and claim, as root. `run-nfs-attack.sh` did exactly that: a pod at uid
1004 beside a victim, before the fix, read the victim's PVC (`open: port 55628:
victims-file`). The kernel's `mountd` already refused it a mount of the pods
directory -- macOS requires reserved ports for MOUNT by default -- but the
userspace per-PV servers had no such rule. Now the node sets
`vfs.generic.nfs.server.require_resv_port=1`, the per-PV servers accept a
connection only from a port below 1024, and both mount with `resvport`. Only
root can bind a reserved port, and a pod's processes are not root; the runtime's
own mounts are the kernel's NFS client, which is. After the fix the same attack
reads nothing.

Not done: `subPath`, fsGroup and ownership semantics beyond `-mapall=root`, and
block volumes.

### All three kinds of pod, one network

Every test before this had Linux pod VMs on the Mac and macOS pods; none had a
Linux *machine*. `run-macos-interop.sh` adds one beside the macOS machine and
sends TCP and UDP between them, by address and by Service name:

```
ferry-mac-macos-containers   macOS 26.6.2           ferry://0.10.0       vm-per-pod
mac-0                        macOS 26.6.2           ferry-darwin://0.1.0 shared-macos
worker-0                     Debian GNU/Linux 12    containerd://2.3.5   shared

=== a Linux machine's pod calls the macOS pod        (address, ClusterIP, name)
    mac-web (uid 1001) sees peer 192.168.240.3
=== the macOS pod calls the Linux machine's pod
    by address, tcp:  hello-from-a-linux-machine-pod
    by name, tcp:     hello-from-a-linux-machine-pod
    by name, udp:     udp reply: udp-hello-from-a-linux-machine-pod
--- the resolver ferry-darwin wrote
    cluster.local resolves through 10.190.34.2     (the machines' CoreDNS, once it had endpoints)
```

macOS to Linux worked at once; Linux to macOS took two fixes, each found by
`tcpdump` on the macOS node (`run-interop-trace.sh`):

1. **The SYN arrived and nothing answered, with pf off.** A Linux machine
   routes a peer's pod slice via the peer's machine-network address, and
   masquerades -- so the SYN comes in on the macOS node's machine card, from
   the Linux machine's own address, for a pod address that lives on the pod
   card. macOS had `net.inet.ip.check_interface=1`, the strong host model, and
   dropped it. `ferry-darwin` sets it to 0 when it takes the pod network: the
   weak host model, Linux's default. pf still decides what an address accepts.
2. **Then the SYN-ACK was never sent.** The pod's socket is bound to its
   address, on the pod card, and macOS scopes a bound socket's routes to that
   card -- which has no route to the machine network, so the reply was
   dropped before it left. A route in the pod card's scope out through the
   machine card is refused ("Network is unreachable"); but every machine is
   also on the pod switch at .1 of its slice, and a scoped *host* route to the
   Linux machine's address via that pod-switch address takes the reply back
   over the switch, where the Linux machine accepts it. `ferry-darwin` keeps
   one per node on the machine network, from the Node list -- a route agent
   the counterpart of the Linux machines' (`routes.go`). Verified by hand
   first: the same connection failed without the route and completed with it.

**UDP to a ClusterIP** needed `sendto`: a UDP socket that never connects names
its destination per datagram, so the shim now rewrites and source-binds there
too. DNS itself is unaffected -- it goes through mDNSResponder.

### Mode 1, built: a pod that is its own macOS VM

The plan above put mode 1 inside `ferry-cri` on the Mac -- a `MacPod` holding a
booted guest, containers as processes in it. What is built instead reuses the
mode-2 machinery: **a macOS pod's VM is a macOS Machine that runs one pod.** A
Machine gains `spec.isolation: vm`; ferry-machined boots it exactly like a
shared macOS machine but registers it `ferry.dev/mode=macos-vm` with the
kubelet's `maxPods: 1`, so the scheduler puts one pod on it and no more. The pod
runs as **root** (`ferry-darwin -pod-vm`): a uid of its own is what keeps pods
that share a kernel apart, and here there is no other pod, so it would only keep
the pod from what a VM of its own is for. `run-macos-vm.sh`, nothing declared:

```
=== 1. a Job of two macOS VM pods
    both Running after 35 s
    macos-vm-grdt8   ferry-macvm-4cpu-4gi   1     (PODS capacity: 1)
    macos-vm-2ng4j   ferry-macvm-4cpu-4gi   1
=== what each pod saw
    uid 0, kernel boot session 1A2F29BF-...   booted Sat Sep 26 22:33:37 2026
    sysctl -w: allowed    renice -5: allowed
    uid 0, kernel boot session 49B3D5A7-...   booted Sat Sep 26 22:33:39 2026
    sysctl -w: allowed    renice -5: allowed
=== 2. a third ferry-macos-vm pod
    macvm-third: Pending
    macos-vm-grdt8   ferry.dev/mode,ferry.dev/spent      (both slots full)
    macos-vm-2ng4j   ferry.dev/mode,ferry.dev/spent
=== 3. the Job is done: its machines go, and the third pod gets a fresh one
    macvm-third: Succeeded on macos-vm-q72fh (the Job's were: macos-vm-grdt8 macos-vm-2ng4j)
    uid 0, kernel boot session EFD4C420-...   /private/tmp: . ..
    no machines after 207 s
```

- **Each pod is a kernel of its own.** Distinct boot-session UUIDs, and the
  third pod's `/private/tmp` is empty where the Job's pods had written -- a
  fresh clone of the golden image, nothing of the pod before it.
- **The pod is root, and it is real root.** `sysctl -w` and `renice -5`, which a
  shared-macos pod's uid is refused, both succeed. That is the point of paying
  for a whole guest: a CI step that wants to install a kext, change a system
  setting or run under `sudo` can.
- **A VM is single-use.** `maxPods: 1` alone is not: a finished pod stops
  counting, so the next pod would land in the guest the last one had root in.
  ferry-machined taints the node `ferry.dev/spent` (its own key, so the
  default-runtime reconciler never removes it) once a pod is bound to it, and
  `ferry-darwin` refuses a second pod for the moment before that taint lands. So
  the machine is empty when its pod ends, Karpenter takes it away, and the next
  pod gets a clone.
- **Two slots, shared with shared-macos machines.** ferry-karpenter offers
  `ferry-macvm-*` shapes (pods capacity 1) from a `macos-vm` NodePool, only
  while one of the Mac's two macOS guests is free -- the same count mode-2
  machines draw on. Two Job pods took both; the third waited Pending with a
  reason until a slot freed, then got its own.
- **RuntimeClass `ferry-macos-vm`** carries `nodeSelector: {ferry.dev/mode:
  macos-vm}` and the toleration for its taint, beside `ferry-macos-shared`.
  Both are shipped in `manifests/runtimeclasses.yaml`, inert on a Mac with no
  macOS image.

What this costs over a `MacPod` in ferry-cri is a whole node -- a kubelet, a
registration, a Karpenter round trip -- per pod, and a slower start (35 s to two
pods Running here, against ~10 s to boot a bare guest) because the kubelet and
CRI come up inside it. What it buys is that mode 1 is mode 2 with `maxPods: 1`:
no second guest-managing path, no `MacPod` type, the same boot, network,
Services, volumes and streaming a shared macOS machine already has. The kubelet
running inside the pod's own VM does mean a root pod can reach that node's
kubelet credentials -- acceptable because the VM is thrown away after the one
pod, but noted.

## Also possible, not asked: the Mac node itself

The Seatbelt runtime needs no VM at all. The Mac is already a darwin node, so
`ferry-cri` could run a `macos-native` RuntimeClass as Seatbelt'd processes on
the host: no two-VM ceiling, 15 ms starts, no golden image -- and the weakest
isolation of anything here, since the workload runs on the user's own OS as
the user.

## What this does not establish

- Both modes are built: shared-macos (a kernel shared between pods) and macos-vm
  (a pod that is its own VM), the second as a Machine with `maxPods: 1` rather
  than the `MacPod`-in-ferry-cri plan above. The slot count is one ledger for
  both kinds of macOS guest -- Karpenter counts every `spec.os: darwin` Machine
  against the two -- but any macOS VM on the Mac that is not a Machine is
  invisible to it.
- The early Mode 1 measurements (boot time, memory, the two-guest ceiling) were
  taken with the standalone `macvm` prototype, not through Kubernetes; the
  macos-vm path re-measured start (35 s to two pods Running) but not idle memory
  per guest, which is still one reading of one 4 GiB guest.
- Xcode in a guest was not tried; it is not in the golden image and would
  dominate its size.
- Why clone boots split between ~10 s and ~20 s is a guess.
- Mode-1's kubelet runs inside the pod's own VM, so a root pod can read that
  node's kubelet credentials. It is acceptable only because the VM is discarded
  after the one pod.
