# A process that holds the pod network, so it outlives a ferry-cri that dies

**Question.** [Experiment 22](../22-vmnet-lifecycle/FINDINGS.md) made a clean
`ferry down` release the vmnet subnet at once. A ferry-cri that dies *without*
releasing -- a crash, `kill -9`, the ten-second stop timeout in `ferry down` --
still left the next start without its subnet. Can a separate process hold the
network, the way Apple's `container-network-vmnet` does for its runtime
helpers, so that the subnet survives ferry-cri?

**Answer.** Yes, with one hard constraint. The process that creates a vmnet
network is the network's lifetime: nothing anyone else holds keeps it alive.
So the owner has to create it, and ferry-cri has to stop when the owner goes.
ferry now does both, through `ferry-netd`.

## What ferry-cri dying used to cost

Measured on this branch before ferry-netd, a single-Mac cluster on its slice
`10.244.0.1/24` with pods running:

```
kill -9 ferry-cri         10:23:54
ferry restart             runtime on network 192.168.66.0/24   (moved off its slice)
```

And the slice stayed refused. Fifteen minutes later, with nothing having asked
for it in between -- so this is not the refusal-renews-the-reservation effect
of experiment 22, which clears after ninety seconds of silence -- the next
start was still refused `10.244.0.1/24`, with no bridge for it on the Mac and no
other ferry using it. A network whose creator dies uncleanly while VMs are
attached is held far longer than the minute experiment 07 measured.

Alone, a node that moves changes every pod address and rolls CoreDNS. Joined to
other Macs it cannot move, since the others route its slice to it, so it waits
200 seconds and then refuses to start.

## The trials

`owner.swift`, signed with the virtualization entitlement, run by `run.sh`. Each
trial uses its own subnet, since a refused ask renews a reservation.

| | what happens | then the subnet is asked for |
|---|---|---|
| T1 | owner releases cleanly (`CFRelease`) | **granted** |
| T2 | owner is `kill -9`ed, with no interfaces on the network | **granted** |
| T3 | a client rehydrates the serialization, is `kill -9`ed; a second client rehydrates after it | second client gets the network |
| T4 | a client rehydrates and is `kill -9`ed; the owner then releases cleanly | **granted** |
| T5 | asked for while the owner holds it | refused (1001) |

So a serialization can be handed to client after client, a client dying holds
nothing once the owner lets go, and the owner's hold is exclusive. T2 also says
the long hold above is not the network object itself: a creator dying with
nothing attached frees its subnet at once. It is the creator dying with VMs
attached.

`vmnet_interface_start_with_network`, which would have let these trials attach
an interface the way a VM does, crashed inside vmnet in every process tried
(`EXC_BAD_ACCESS` in `__vmnet_interface_start_with_network_block_invoke_2`, the
block retained or not). ferry's VMs attach through Virtualization.framework, not
that call, so the cases with interfaces were run on a real cluster instead.

## On a real cluster, with ferry-netd

ferry-netd creates the network and hands ferry-cri its serialization over a
Unix socket; ferry-cri rehydrates it and attaches pod VMs to it as before.

| | before ferry-netd | with ferry-netd |
|---|---|---|
| clean `ferry restart` | same subnet | same subnet |
| `kill -9` ferry-cri, then `ferry restart` | **moved** (10.244.0.0/24 to 192.168.66.0/24) | **same subnet**, new pod reachable from the Mac |
| clean `ferry down` / `up` after that crash | -- | same subnet |
| `kill -9` ferry-netd | -- | ferry-cri stops itself in 0.55 s; next start on a new subnet |

`ferry down` decides what happens to ferry-netd from how ferry-cri went. After a
clean stop it stops ferry-netd too, and the subnet is released at once, as
before -- a stopped ferry holds nothing. After an unclean one (ferry-cri had
already died, or had to be killed) it leaves ferry-netd running, and the next
`ferry up` reuses it:

```
✓ ferry-netd kept: ferry-cri did not stop cleanly, so the next start reuses its subnet
✓ pod network held over from the last run by ferry-netd
```

That covers the login agent's recovery too, which is `ferry down` then exit
then `ferry up`. ferry-netd calls `setsid()` at startup, so launchd ending what
is left of the exiting agent job does not take it with it: its process group
and session are its own (pgid 96932 against ferry-cri's 96771). The agent path
itself was not run end to end here.

## The constraint: the network ends with its creator

With ferry-netd killed under a running cluster:

```
before:  pod 192.168.77.5 -> one
kill -9 ferry-netd
after:   pod 192.168.77.5 -> unreachable
new pod: 192.168.77.6, Running, Ready -> unreachable
```

ferry-cri still held a rehydrated reference, and it kept nothing alive. That is
the failure ferry is most careful about elsewhere: pods that report Ready with
nothing able to reach them.

So ferry-cri keeps its connection to ferry-netd open, and ferry-netd keeps it
open for as long as it lives. When it closes and ferry-cri did not ask to stop,
ferry-cri stops through its normal clean shutdown:

```
==> ferry-netd has gone, and the pod network with it; stopping so the cluster restarts
==> stopping pods and releasing the pod network
==> stopped
```

0.55 s from the kill. Whatever restarts the cluster -- the login agent, or
`ferry up` -- brings it back on a network that exists. A ferry-netd crash
therefore costs what a ferry-cri crash used to: a new subnet. It is a process
with no VMs and about two hundred lines of vmnet and sockets, which is why it is
the one holding the network.

## What this leaves

- **A ferry-netd that dies still moves the subnet**, for the reason above. It is
  now the only thing whose crash does.
- **Extra nodes on one Mac** (`ferry node add`) still create their own
  networks. The main node and a joined Mac use ferry-netd, and a joined Mac is
  the case where moving was not an option.
- **Orphaned subnets do not come back quickly.** This experiment's own crash
  tests left `10.244.0.1/24`, `.66`, `.77` and `.88` refused for the rest of the
  session, the cluster starting on the next free candidate each time. Experiment
  22 found a reboot clears them. ferry-netd prevents new ones; it cannot return
  ones already orphaned.

## Reproducing

```
swiftc -O owner.swift -o owner
codesign --force --sign - --entitlements entitlements.plist ./owner
./run.sh
```

On a cluster: `kill -9 "$(cat /tmp/ferry-run/ferry-cri.pid)"; ferry restart`,
and compare the `runtime on network` line with the one before.
