# Running more than one ferry at once

```
$ ferry profile
profile default
  state       /Users/you/.ferry
  runtime     /tmp/ferry-run
  node name   ferry-mac
  pod network 10.244.0.0/16
  api server  https://192.168.1.29:6443
  node ports  30000-30199

  This is the main checkout, so nothing is renamed or moved.
```

A second checkout gets its own everything, without being asked to:

```
$ cd .claude/worktrees/gpu-work && ferry profile
profile gpu-work
  state       /Users/you/.ferry-gpu-work
  runtime     /tmp/ferry-run-gpu-work
  node name   ferry-mac-gpu-work
  pod network 10.151.0.0/16
  api server  https://192.168.1.29:7443
  node ports  30200-30399
```

Both clusters then run at the same time and do not notice each other.

## Why this exists

ferry kept its state at fixed paths and bound fixed ports, which is right until a
second copy runs on the same Mac -- and with git worktrees that happens without
anyone deciding to. Two clusters then shared one etcd, one set of certificates,
one set of sockets, and both tried to reserve the same vmnet subnet.

What that looked like from outside was a cluster that had been working and
quietly stopped. It cost two full rebuilds of two machines in one afternoon
before it was recognised as a design problem rather than an accident.

## What is named after the profile

| | default | a worktree |
|---|---|---|
| cluster state | `~/.ferry` | `~/.ferry-<profile>` |
| runtime state | `/tmp/ferry-run` | `/tmp/ferry-run-<profile>` |
| sockets | `/tmp/ferry-cri.sock` | `/tmp/ferry-cri-<profile>.sock` |
| node name | `ferry-mac` | `ferry-mac-<profile>` |
| pod network | `10.244.0.0/16` | `10.<150+n>.0.0/16` |
| API server | 6443 | 6443 + n×1000 |
| etcd | 2379/2380 | +n×1000 |
| controller, scheduler | 10257/10259 | +n×1000 |
| kubelet | 10250 | +n×1000 |
| streaming | 10350 | +n×1000 |
| pod switch | udp/8472 | +n×1000 |
| added nodes | 10701-10997 | +n×1000 |
| node ports | 30000-30199 | 200 each |

The default profile keeps every path and port it had, so a single checkout is
unaffected.

`ferry node add` takes three consecutive ports out of that thousand per node --
a kubelet, its healthz and a streamer -- from 10701 upward, which is the largest
run of the thousand nothing above has claimed. That is what caps a profile at 99
added nodes: the arithmetic runs out before the Mac does. An added node's
sockets are named after the profile too, like every other socket ferry opens.

## The directory, not the branch

The profile is the checkout's directory name. A branch looks like the obvious
choice and is not: it changes under a running cluster the moment someone checks
something else out, two worktrees can sit on the same branch, names contain
slashes, and a detached HEAD has no branch at all. A worktree's directory is
stable for as long as the worktree is.

`FERRY_PROFILE` overrides it.

## The number is allocated, not hashed

Each profile needs a number, for the port offsets and the subnet. The first
attempt hashed the name, and put two of three worktrees on the same number --
which is exactly the collision this change exists to prevent, reintroduced by the
fix for it. With a handful of profiles a birthday collision is likely rather than
exotic.

So numbers are claimed and written down in `~/.ferry-profiles`:

```
1 gpu-vsock-offload
2 cni-plugins
3 explore-kine
```

Claiming happens under a directory lock, because two checkouts starting at once
is the case being designed for.

## Known limits

- **Fifty profiles.** Beyond that the numbers run out; nothing checks.
- **The 128 VM ceiling is still the machine's**, shared by every cluster on it,
  as is the vmnet limit of 32 networks.
- A profile's number is never released. Removing a line from
  `~/.ferry-profiles` frees it, once nothing is using it.
