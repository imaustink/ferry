# Guest kernel

`build-kernel.sh` produces `vmlinux-arm64`, the kernel ferry boots each pod VM
with. `ferry` uses it automatically when present and falls back to the
kata-containers kernel otherwise.

## Why not just use the kata kernel

It boots pods perfectly well, but it ships netfilter without the NAT
extensions, and it is monolithic so nothing can be loaded at runtime:

```
iptables -t nat -A OUTPUT ...
  Warning: Extension DNAT revision 0 not supported, missing kernel module?
  DNAT rejected
```

A pod that cannot do NAT cannot program its own Service rules, which is what
forces ClusterIP routing onto the host. That brings the root requirement and an
extra hop through the Mac for every Service connection.

## What this builds

Apple's own kernel configuration from the Containerization repository, which
already enables what is needed:

```
CONFIG_NF_NAT=y   CONFIG_NF_CONNTRACK=y   CONFIG_NF_TABLES=y   CONFIG_NF_NAT_MASQUERADE=y
```

The configuration is fetched rather than vendored, so it tracks what the
framework expects. The script refuses to build if those symbols are missing,
since a kernel without them would not fix anything.

On top of it, three things of ferry's own. The first is `usb-storage.config`,
appended to Apple's configuration: USB mass storage, the one way a disk reaches
a VM that is already running, which is how a `ferry-local-block` claim reaches
a machine. The drivers probe only when there is a USB controller, and only
machines get one. The other two are there because a pod VM's memory is what
bounds how many pods a Mac holds
([experiments/32-pod-memory-footprint](../experiments/32-pod-memory-footprint/FINDINGS.md)):

- `patches/` are applied to the source after Apple's build unpacks it. One so
  far: virtio disks are not rotational, which takes read-ahead from 8 MiB to
  the kernel's 128 KiB and an idle pod from 226 MiB of host memory to 150.
- `slim.config` is appended to Apple's configuration: no display stack, no KVM,
  no hibernation or kexec, one NUMA node, a 128 KiB log buffer. The image goes
  from 27.8 MiB to 19.5, and it is paid for twice per pod, once in the guest
  and once in Virtualization.framework's copy of it: 150 MiB to 131.

The kernel records what it was built from in `vmlinux-arm64.inputs`. When a
patch, either configuration fragment or the build script changes, `ferry kernel` rebuilds rather than
reporting the kernel present, `ferry doctor` warns, and `release/build.sh`
refuses to ship the old one.

The build runs in a Linux container for the cross toolchain. Apple drives it
with their `container` CLI; this uses Docker, which does the same job and is
usually already installed.

```sh
./kernel/build-kernel.sh      # or: ferry kernel
FORCE=1 ./kernel/build-kernel.sh
```

Roughly five minutes on an M4 Max, and about 1.5 GB of scratch under `.build/`.

## Result

```
kernel: 6.18.5-ferry
DNAT RULE ACCEPTED
-A OUTPUT -d 10.96.0.99/32 -p tcp -m tcp --dport 80 -j DNAT --to-destination 127.0.0.1:8080
conntrack present
```
