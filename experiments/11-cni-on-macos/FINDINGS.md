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

## What is not proven

Honest boundary — everything above is measured, everything here is reasoning:

- **In-guest plugin execution.** `ns.WithNetNSPath("/proc/self/ns/net", …)` should
  be a legal no-op — `setns` to the netns you are already in — which is what
  would make a `main`-shaped plugin run correctly inside the pod VM against its
  own root netns. Not tested.
- **`portmap` end to end.** It needs an iptables or nft backend in-guest. ferry
  already ships `nft`, and `portmap` has an nftables backend, so this is
  plausible. Not tested.
- **Chain ordering across the boot boundary.** The meta chain runs after the VM
  is up, so a plugin that fails leaves a booted pod to unwind. CNI's `DEL` is
  defined to be idempotent, which helps, but the failure path is unexamined.

`portmap` does cross-build to a static `ELF 64-bit LSB executable, ARM aarch64`,
so the artifact the guest half needs exists.

## Next

1. **Prove the in-guest half** by getting `portmap` to deliver a real hostPort
   into a ferry pod. It is the only unproven link, and it is also a feature ferry
   is missing — so the experiment and the deliverable are the same work.
2. **`ferry-cni`** — the dispatching `invoke.Exec`, plus a `ferry-vm` main plugin
   that is the VM boundary.
3. **Retire `RotatingAddresses`** in favour of a conflist with `host-local`.
   Mostly mechanical once (2) exists, and it is what closes the restart bug.

## Reproduce

```sh
cd experiments/11-cni-on-macos
./survey.sh      # which plugins and which runtime build for darwin/arm64
./try-ipam.sh    # full ADD/DEL lifecycle against host-local, natively
```

Go 1.24+. Nothing here needs root, Docker, or a VM.
