# Experiment 11 — CNI on macOS

**Question.** ferry allocates pod addresses itself, in Swift, and the docs call
this "ferry has no CNI." Every other Linux-shaped dependency got a clean seam —
the kubelet, kube-proxy, CRI. Why is this one different, and does it have to be?

**Answer: it does not.** ferry can run real, unmodified CNI plugins today, and
the CNI runtime itself builds native for darwin/arm64. The gap is not "CNI needs
Linux." It is that ferry never adopted the protocol.

## The reframe

CNI is a *protocol* — JSON on stdin, JSON on stdout, verb in the environment,
one process per invocation. It is not a kernel API. Whether a given plugin needs
Linux is a property of that plugin, not of CNI.

Building the whole upstream suite for darwin/arm64 splits it cleanly:

| plugins | darwin/arm64 | why |
|---|---|---|
| `ipam/host-local`, `ipam/static` | **native Mach-O** | pure computation — files and arithmetic |
| `ipam/dhcp` | Linux-only | netlink |
| `main/*` — bridge, ptp, macvlan, ipvlan, host-device, loopback, vlan, tap | Linux-only | netlink, netns |
| `meta/*` — portmap, bandwidth, tuning, firewall, sbr, vrf, bridge-ext | Linux-only | netlink, iptables/nft |

`libcni`, `pkg/invoke` and `pkg/types/100` — the runtime, not the plugins —
build for darwin/arm64 unmodified.

> **Method note.** A first pass reported everything except IPAM as Linux-only for
> the wrong reason: the module's transitive deps were unresolved and every build
> failed with `missing go.sum entry`. `survey.sh` resolves deps first. The split
> above survives that fix, but it is an easy result to fake by accident.

## Why that line falls exactly where ferry already cuts

A `main` plugin's entire job is *create a netns and put an addressed interface
in it*. **That is what the hypervisor does.** ferry does not lack a CNI plugin;
ferry *is* the main plugin. What was missing is the runtime around it.

So the chain maps onto ferry's pod lifecycle without forcing anything:

```
ipam        (host, native Mach-O)   before boot -- ferry needs the address first
                                    anyway, because VZ cannot hotplug a device
ferry-vm    (host, native, ours)    boot the VM; this IS the main plugin
meta chain  (guest, ELF)            after boot, against the VM's own root netns
```

The no-hotplug gotcha stops being a wart. It is the reason the IPAM/main split is
*forced* rather than chosen.

## The seam

`libcni` reaches plugins through a public interface, and upstream's own comment
says implementations may be substituted:

```go
// Exec is an interface encapsulates all operations that deal with finding
// and executing a CNI plugin. Tests may provide a fake implementation
// to avoid writing fake plugins to temporary directories during the test.
type Exec interface {
	ExecPlugin(ctx context.Context, pluginPath string, stdinData []byte, environ []string) ([]byte, error)
	FindInPath(plugin string, paths []string) (string, error)
	Decode(jsonBytes []byte) (version.PluginInfo, error)
}
```

`libcni.NewCNIConfigWithCacheDir(path []string, cacheDir string, exec invoke.Exec)`
takes it.

This is the same shape as the kube-proxy seam in experiment 06. There the
proxier talked to a `knftables.Interface` and ferry supplied a rendering
implementation instead of a kernel. Here the runtime talks to an `invoke.Exec`
and ferry supplies a *dispatching* implementation:

| plugin binary | where ferry runs it |
|---|---|
| Mach-O (`host-local`, `static`, `ferry-vm`) | fork on the Mac |
| ELF (`portmap`, `bandwidth`, `tuning`, …) | ship into the pod VM and exec there |

The second row needs no new mechanism. `guest/build-nft.sh` already packages a
Linux binary with its own musl loader and `PodRuntime` already execs it inside a
pod with `NET_ADMIN`. A CNI plugin is the same trick with a different binary and
`CNI_NETNS=/proc/self/ns/net`.

## Result — the IPAM half, proven

`host-local` builds as `Mach-O 64-bit executable arm64` and drives a full
lifecycle natively, with no Linux involved:

```
==> ADD pod-alpha    10.244.7.2/24  gw 10.244.7.1  routes 10.244.0.0/16
==> ADD pod-beta     10.244.7.3/24
==> ADD pod-gamma    10.244.7.4/24

==> lease store
  10.244.7.2 -> pod-alphaeth1
  10.244.7.3 -> pod-betaeth1
  10.244.7.4 -> pod-gammaeth1
  last_reserved_ip.0 -> 10.244.7.4

==> DEL pod-beta     exit 0
==> lease store after release
  10.244.7.2
  10.244.7.4
```

That is `ClusterAddresses.swift` — except it is upstream, and the leases are on
disk.

## What it buys

**It fixes a live bug.** `PodRuntime` holds

```swift
private var clusterAddresses: RotatingAddresses?
```

and `RotatingAddresses` keeps `next` and `inUse` in memory only. Everything else
in ferry-cri persists to `stateDir` — images, podmap, ext4 clones — but IPAM does
not. Restart ferry-cri with pods running and it hands out from `.2` again, onto
addresses those pods still hold. `host-local`'s lease directory fixes that for
free, and it is the same fix upstream ships to everyone else.

Beyond that:

- **hostPort**, which ferry does not implement today — `host_port` appears only
  in the CRI proto — via upstream `portmap`.
- `bandwidth` for traffic shaping, `tuning` for per-pod sysctls, `firewall` as a
  second NetworkPolicy path.
- Pod networking described by a conflist rather than compiled into Swift.
- Ranges, `rangeStart`/`rangeEnd`, multiple ranges and IPv6 come from a config
  file instead of being ferry's to write.

And the claim in the README gets stronger *and* truer: not "we had to write our
own," but **ferry is a CNI runtime whose main plugin is a hypervisor.**

> **Superseded in part.** The restart bug above was real and is fixed, but not
> this way. While this was being built, ferry put the Mac on the pod network:
> a node's vmnet network became its slice of the cluster CIDR, so vmnet itself
> allocates pod addresses and `RotatingAddresses` went away with the translation
> layer that needed it. See [docs/POD-NETWORK.md](../../docs/POD-NETWORK.md).
> What that leaves for CNI is written below — it turns out to be the more honest
> arrangement, because ferry now *knows* an address rather than choosing one.

## Result — the guest half, proven

`portmap` runs **inside a pod's virtual machine**, against that VM's own root
netns, and delivers a real `hostPort`. It is upstream's binary, unmodified,
cross-built for `linux/arm64` and shared into the pod at `/opt/cni/bin`.

```
==> a pod that asks for a hostPort
    pod ip     10.244.0.3   -- and the Mac is on that network, so it dials it directly

==> what portmap wrote, in the pod's own kernel
    table ip cni_hostport {
    	chain hostports {
    		tcp dport 18080 dnat to 10.244.0.3:80 comment "sandbox000000000000006"
    	}
    }

==> reaching it
    10.244.0.3:18080       hello from a pod VM
      the pod's own address -- portmap alone, no host involvement
    127.0.0.1:18080        hello from a pod VM
      the node -- which is this Mac, so ferry-proxy carries the last hop
```

UDP too, at every hop:

```
  container port (10.244.0.4:9999)        hello udp from a pod VM
  pod hostPort (10.244.0.4:19999)         hello udp from a pod VM
  node hostPort (127.0.0.1:19999)         hello udp from a pod VM
```

So ferry has hostPort, and did not write it.

### Three things the guest half turned on

**CNI already knows about runtimes shaped like this.** After a successful ADD,
`skel` checks that the plugin did not end up in the namespace named by
`CNI_NETNS` — on Linux that means a plugin leaked into the container, which is a
bug. Here it is the design, so a correctly programmed pod reported

```
{ "code": 8, "msg": "plugin's netns and netns from CNI_NETNS should not be the same" }
```

*after* writing every rule correctly. The fix is not a patch: upstream ships
`CNI_NETNS_OVERRIDE` for exactly this, and ferry sets it on guest-dispatched
plugins only — the one place where it is true.

**`nft` had to become an ordinary command.** `portmap`'s nftables backend goes
through `knftables`, which does `LookPath("nft")` and execs it. ferry already
ships `nft` into every pod, but invoked through an explicit musl loader, because
a pod's image may not share its libc. A plugin cannot be told to do that. So
`build-nft.sh` now bakes the loader into the binary with `patchelf`, and the
same bundle serves both callers.

**SNAT is off.** `portmap` writes `route_localnet` so a connection from 127/8
can cross a routing boundary, and a pod mounts `/proc/sys` read-only, so that
write fails and takes the ADD with it. Nothing here needs it: a hostPort
connection arrives from the Mac with a real source address, never from loopback.
`"snat": false` in the conflist, and the read-only `/proc/sys` is recorded below
as the real boundary it is.

## What was built

**`ferry-cni`** — the CNI runtime, in Go, beside ferry's other components.
It holds the dispatching `invoke.Exec` the seam was named for:

| plugin binary | where ferry-cni runs it |
|---|---|
| Mach-O (`ferry-vm`, `static`, `host-local`) | forks it on the Mac |
| ELF (`portmap`, `bandwidth`, `tuning`) | ships it into the pod VM and execs it there |

Nothing configures that split. It is *discovered*: a plugin runs wherever its
binary was found, and the two plugin directories hold two architectures. The
guest side needs no new mechanism — ferry-cri already accepts exec requests on a
unix socket, because that is how `kubectl exec` works here. A CNI plugin needed
three additions to that protocol: an environment, because the verb travels in
one; `NET_ADMIN`, because programming a kernel takes it; and root, because a
hardened pod cannot lend a capability it does not itself hold.

**`ferry-vm`** — the main plugin, and deliberately almost empty. A main plugin
creates a netns and puts an addressed interface in it; the hypervisor does that.
What is left is the part that is genuinely CNI's: describe the interface, and
delegate the address to an IPAM plugin.

**Who chooses the address, and why it is not this.** vmnet does. A node's vmnet
network is its slice of the cluster CIDR, which is what puts the Mac on the pod
network, and `VmnetNetwork.createInterface` takes no address argument. So the
host half of the chain is *told* the address rather than asked for one, through
upstream's `static` IPAM and CNI's own `ips` capability — the same mechanism
`portMappings` uses to reach `portmap`:

```json
{ "type": "ferry-vm",
  "capabilities": { "ips": true },
  "ipam": { "type": "static" } }
```

That is not a workaround. `static` exists for a runtime that already knows an
address, and it leaves the chain intact: the host half still produces the
prevResult the guest half needs, the result cache still holds it, and DEL still
unwinds. `host-local` is built and shipped for anyone who configures it; ferry's
default simply does not need an allocator, because something upstream of CNI
already allocated.

**hostPort's last hop is ferry's.** `portmap` makes the mapping real on the
pod's own addresses; Kubernetes means the node's, which is this Mac. ferry-cri
writes the mappings down and ferry-proxy listens, forwarding to the pod at the
same port so the pod's own rule is what rewrites it — TCP through the stream
proxy, UDP through the datagram one.

## What is not proven

Honest boundary — everything above is measured, everything here is reasoning:

- **Per-pod sysctls.** `tuning` is built and shipped, and it cannot work yet for
  the reason `snat` had to be turned off: `/proc/sys` is read-only inside a pod.
  A pod is a whole virtual machine here, so mounting it writable would confine
  the blast radius to that pod's own kernel — which is a stronger argument than
  Linux can make, and still an unexamined change.
- **Hairpin.** With `snat` off, a container reaching its own hostPort through a
  host address is untested.
- **`bandwidth`** is built and never invoked; nothing in the CRI surface asks
  for shaping.
- **A chain that interleaves the halves** is rejected rather than handled. The
  VM boots once, between the stages, so the split has to be a prefix.

## Next

1. **Writable `/proc/sys` in a pod**, which turns `tuning` on and removes the
   one place ferry had to disable upstream behaviour rather than support it.
2. **`firewall` as a second NetworkPolicy path**, now that the guest half is
   real — worth comparing against what `ferry-netpol` compiles today.
3. **A conflist per node, from a file**, rather than generated: `--cni-conflist`
   accepts one already, so this is documentation and a default, not code.

## Reproduce

```sh
cd experiments/11-cni-on-macos
./survey.sh          # which plugins and which runtime build for darwin/arm64
./try-ipam.sh        # ADD/DEL against host-local, natively, no cluster needed

ferry build && ferry up
./try-hostport.sh    # portmap inside a pod VM, delivering a real hostPort
```

Go 1.24+. `survey.sh` and `try-ipam.sh` need no root, Docker or VM;
`try-hostport.sh` needs a running cluster.

## Incidental, and worth knowing

Found while getting the above to run, all fixed here:

- **The kubelet's node memory was free pages only.** macOS deliberately keeps
  very few, so a Mac with gigabytes to spare reported a few hundred megabytes,
  tainted itself `MemoryPressure`, and scheduled nothing. `cadvisor_darwin` now
  counts the pages the kernel can take back without writing anything out, which
  is what Linux's `MemAvailable` exists to say.
- **`build-kubelet.sh` could not apply an overlay that adds a directory.** BSD
  `install` does not create parents, so a fresh clone failed on
  `cmd/ferry-proxyd`.
- **A vmnet subnet can be shadowed by a route the Mac already has.** On a
  machine with a corporate VPN, a fallback onto `192.168.77.0/24` resolved out
  of `en0` rather than to the bridge, and the Mac could not reach its own pods —
  while the pods could reach it. ferry falls through its candidate list on vmnet
  errors; it does not check whether a candidate is routable to the bridge it
  just made.
