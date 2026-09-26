# What actually happens to a vmnet network

ferry believed that vmnet subnets leak: that a network created by a process which
has since exited stays claimed, and that the only way forward is to try a
different subnet. It carries fifteen fallback candidates on that basis, and after
a run of restarts every one of them was refused:

```
failed to prepare runtime: unsupported:
  "failed to create vmnet network with status vmnet_return_t(rawValue: 1001)"
```

The belief is wrong, and `probe.swift` shows it. It calls vmnet directly, signed
with the same entitlement ferry-cri uses. Unsigned, every call fails with
`VMNET_MEM_FAILURE`, so check the signature before reading any other result.

## Three facts

**A reservation is reclaimable the moment it is released.** The same subnet,
created and released ten times in a row:

```
$ ./probe cycle
attempt 1: created and released 192.168.44.1
...
attempt 10: created and released 192.168.44.1
```

**There are 32 of them, system-wide.** Holding distinct subnets without releasing:

```
$ ./probe hold
held 32 networks, then 192.168.52.1 FAILED with vmnet_return_t(rawValue: 1001)
```

This is the same kind of ceiling as the 128 concurrent VMs, and it is shared with
everything else on the Mac that uses vmnet.

**A network that was never attached to a VM does not outlive its process.**
Creating one, exiting without releasing, and asking for the same subnet again
succeeds:

```
$ ./probe leak
created 192.168.45.1, exiting without CFRelease
$ ./probe leak
created 192.168.45.1, exiting without CFRelease
```

**A network ferry actually used does outlive it, for about a minute.** This is
the one that matters, and the probe above does not show it. The probe never
starts an interface, and ferry's pods do. Asking for each subnet ferry had used
during one afternoon:

| subnet | last used | result |
|---|---|---|
| .66 .77 .88 .99 .111 .122 | within the last minute or two | refused |
| .133 .155 .166 .177 .188 .199 .211 .222 | earlier | free |
| .40 .41 .42 .43 | never | free |

Measured directly: a subnet in use was refused, and came back 60 seconds after
`ferry down`.

## So what was failing

The reservations were real, and time-based. ferry burns one subnet per run and
holds it for about a minute, against fifteen candidates and a system-wide cap of
32. A run of restarts inside that window exhausts the list, and ferry will not
start at all. The error said only `VMNET_FAILURE`, which explains none of it.

Waiting for the preferred subnet is not the answer. It costs a minute of startup
for something that was never going to be free. Moving on is right. The cost of
moving is a changed gateway, which is part of the CoreDNS manifest and so rolls
CoreDNS out again. That rollout is what the DNS readiness check had been
misreading.

## Not explained here

`ferry-cri` does not run its SIGTERM handler. The process exits on the signal,
but `==> stopping pods and releasing the pod network` is never printed and
`shutdown()` never runs, so pods are not stopped cleanly either. Whether
releasing the network there would return the subnet any sooner is therefore
untested. The header says `CFRelease` ends the reservation, but `VmnetNetwork`
holds that pointer privately in a struct and offers no way to call it.

## Reproducing

```
swiftc -O probe.swift -o probe
codesign --force --sign - --entitlements entitlements.plist ./probe
./probe cycle        # or: ./probe hold, ./probe leak
```
