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
forces ClusterIP routing onto the host -- and with it the root requirement and
an extra hop through the Mac for every Service connection.

## What this builds

Apple's own kernel configuration from the Containerization repository, which
already enables what is needed:

```
CONFIG_NF_NAT=y   CONFIG_NF_CONNTRACK=y   CONFIG_NF_TABLES=y   CONFIG_NF_NAT_MASQUERADE=y
```

The configuration is fetched rather than vendored, so it tracks what the
framework expects. The script refuses to build if those symbols are missing,
since a kernel without them would not fix anything.

The build runs in a Linux container for the cross toolchain. Apple drives it
with their `container` CLI; this uses Docker, which is equivalent and is
generally already installed.

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
