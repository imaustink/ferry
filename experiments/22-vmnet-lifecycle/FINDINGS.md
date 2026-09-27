# Asking for a vmnet subnet is what keeps it reserved

[Experiment 07](../07-vmnet-leak/FINDINGS.md) established the mechanism and
measured the cost. A vmnet reservation lives as long as its `vmnet_network_ref`,
`CFRelease` ends it, Containerization's `VmnetNetwork` never releases, and a
subnet ferry had used came back about a minute after `ferry down`. A minute is
tolerable, and ferry was built around it. `sliceWaitSeconds` is 90, described
in the source as "about a minute plus enough margin to cover a slow release".

That is not what happens. A slice stayed refused across a 90-second wait, a
three-minute quiet wait and several restarts, and came back instantly after a
reboot. The reboot is the clue. A reboot is not a longer wait. It is a wait
during which **nothing asks**.

## The measurement

One subnet, `10.170.0.1/24`, with ferry fully down for the whole of both runs,
so no bridges and no ferry processes. The only difference is whether anything asked for
it while waiting.

**Asking once a second:**

```
08:14:02 10.170.0.1 refused (vmnet_return_t(rawValue: 1001)); asking every second
08:14:32   still refused after 30 attempts
...
08:24:08   still refused after 600 attempts
08:24:09 gave up after 601 attempts
```

It was refused 601 times over ten minutes and never came back.

**Waiting in silence, then asking once**, on the same subnet, one minute later:

```
08:24:25 waiting 90s without asking
08:25:55 got 10.170.0.1 on the first ask after 90s
```

It came back on the first ask, with no retry.

## What this means

**A refused `vmnet_network_create` renews the reservation it was refused by.**
Polling for a subnet does more than fail. It guarantees the subnet never becomes
available. The more often you ask, the longer it takes, and from outside the
loop looks like a leak that never clears.

Every symptom follows from that:

- `ferry-cri` asks every three seconds for ninety, so a node that finds its
  slice reserved will *always* exhaust its wait and refuse to start. The wait
  cannot succeed by construction.
- A retry loop around `ferry machines enable` behaved the same way, for the same
  reason.
- A reboot appears to be the only cure, because it is the only thing that
  reliably stops anything asking.

## Why there was anything to wait for

The reservation should have ended when ferry stopped. It never did, and the
reason turned out not to be the one experiment 07 guessed.

`ferry-cri` has a signal handler whose first line is `==> stopping pods and
releasing the pod network`. That line has never been printed. `ferry down`
sends SIGTERM and allows ten seconds. The process died in one, and left a crash
report:

```
libdispatch           _dispatch_assert_queue_fail
libswift_Concurrency  _swift_task_checkIsolatedSwift
ferry-cri             closure #1 in closure #14
libdispatch           _dispatch_source_latch_and_call
```

Top-level code in `main.swift` is `@MainActor`-isolated, so a closure written
there inherits main-actor isolation. A dispatch signal source calls its handler
on the queue it was given, a global one, and Swift's isolation check traps. The
process gets SIGTRAP one second after SIGTERM, before the handler's first
statement.

From outside this is indistinguishable from a process exiting on the signal,
which is why it survived so long. The `print` that would have said otherwise
never reached the file. stdout is a log, so it is block-buffered, and the buffer
died with the process.

**So ferry-cri has never shut down cleanly.** Pods were not stopped on
`ferry down`, and the network was never released. The subnet ferry had to wait
for on the next start was one it had abandoned rather than returned.

Two things follow, and both are now done. The handler is built by a function
declared in an ordinary file and taking a `@Sendable` closure, because a
`@Sendable` closure cannot carry actor isolation and so has nothing to trap on.
And anything printed on the way out is flushed, so the next failure of this kind
says so.

`vmnet_stop_interface` is the other half of the lifetime. The header says: *"If
the interface was created via
`vmnet_interface_start_with_network`, this call releases the associated network
object."* Every running pod VM holds a reference. The subnet comes back when the
last interface has stopped **and** ferry has released the one it created. So
the order matters, and releasing before the pods are stopped would be wrong.

## What was done

**Ferry releases the subnet.** `ferry-cri` creates the network itself now and
keeps the reference, because Containerization cannot be asked to. It is a
pinned dependency and holds the reference in a struct with no `deinit` and no
accessor. Ferry needed little of its API, and `VmnetNetwork.Interface`'s
`init(reference:)` is public, so the same code as before still configures pod
VMs. The only thing ferry took ownership of is the network, and
the only reason was to be able to let go of it.

**The handler that does the releasing can run**, which it could not before.

**Retries are spaced past an expiry window** rather than three seconds apart, so
the wait that remains, for a subnet somebody *else* holds, can succeed.

Measured, on a cluster with pods on the slice:

```
==> stopping pods and releasing the pod network
==> stopped
08:57:46 got 10.170.0.1 on the first ask after 0s
```

`ferry down`, then the subnet, asked for with no wait at all. Before this it was
refused for ten minutes of asking and came back only after a reboot.

## Reproducing

```
swiftc -O wait.swift -o wait
codesign --force --sign - --entitlements entitlements.plist ./wait

./wait hold  192.168.77.1        # in one terminal
./wait poll  192.168.77.1        # in another; then kill the holder
./wait quiet 192.168.77.1 90     # compare against this
```

Unsigned, every vmnet call fails with `VMNET_MEM_FAILURE`. Check the signature
before reading any result.

