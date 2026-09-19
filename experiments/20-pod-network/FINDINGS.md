# Experiment 20 — Pods on two machines, reaching each other

**Question.** Milestone 3 of [docs/MACHINES.md](../../docs/MACHINES.md): can a
pod on one machine talk to a pod on another?

**Method.** `ferry-node serve` holds one vmnet network and hosts every machine
on it; `ferry-machined` asks for machines by writing spec files into a
directory; each node takes a slice of the pod network from
`Node.spec.podCIDR` and keeps routes to the others' slices.

Run on macOS 26.6.2, Apple M1 Max, 10 cores, 32 GiB.

## Results

```
  PASS  both machines are Ready
  PASS  both machines are on one network
        addresses: 192.168.96.2 192.168.96.3
  PASS  the target pod stays running
  PASS  pod on worker-b has an address (10.88.1.2)
        ping says: CROSS_NODE_OK
  PASS  a pod on worker-a reaches a pod on worker-b
```

Milestone 3 is met, and it needed less than this experiment spent building.

### One process, one network

Experiment 19 measured that a vmnet network belongs to the process that made
it: a second process asking for the same subnet is refused. So machines are
hosted by one `ferry-node serve` rather than a process each, the way `ferry-cri`
hosts pod VMs, and the two nodes land on one subnet (`192.168.93.2` and `.3`)
instead of on islands.

### Routes, from the node list

Each node reads the Node list with the kubelet's own certificate and installs a
route to every other node's `podCIDR` via that node's address — flannel's
host-gw in a handful of lines, because the parts that make it hard elsewhere
(one segment, a CIDR per node) are already true here.

### A correction: vmnet does carry pod traffic

Partway through, this experiment concluded that vmnet would not carry packets
addressed to pods, and a second network interface per machine was built to work
around it: a socket pair per machine and a userspace switch between them, the
arrangement mode 1 arrived at for pods.

**That conclusion was wrong, and the evidence for it was worthless.** The pod
being probed had exited immediately — `sh: httpd: not found`, because this
Alpine image's busybox has no httpd — so its address had been released. Every
"unreachable" reading was aimed at a pod that no longer existed, including the
readings taken from the node itself, which is what made it look like a network
property rather than a dead target.

With a pod that stays alive, both arrangements work:

| routing between nodes | result |
|---|---|
| over ferry's own switched segment | `CROSS_NODE_OK` |
| over vmnet, no second interface | `CROSS_NODE_OK` |

**The switch has been removed.** It was kept for one more round on the grounds
that mode 1 met a real version of this problem — traffic between two *Macs*,
where vmnet rewrites the source address — but that is precisely the case
`MachineSwitch` could not serve. Mode 1's `PodSwitch` spans machines because it
carries a UDP relay and a peer list; this copy had neither, and forwarded only
between ports on one Mac. So it duplicated the kernel datapath for traffic vmnet
already carries, and was reserved for traffic it could not carry. Cross-Mac work
in mode 2, when it comes, is a port of `PodSwitch`, not a revival of this.

Removing it took a second NIC, a socketpair, a 143-line switch, an annotation
the node published about itself, and a kernel command-line parameter out of the
node image. `BOOT_TO_READY_SECONDS` is 13.1 against 13.8 before, which is within
the run-to-run spread rather than a saving worth claiming.

The lesson is the one ferry's own GAPS.md keeps relearning: a failing probe
proves nothing until the thing being probed is known to be alive. Two
observations agreed with a theory that was still wrong.

## What this means

- **Milestone 3 is met** for one Mac: pods on two machines reach each other
  over ordinary routes.
- **The switch was not needed**, and deleting it is worth more than the code.
- **Milestones 4 and 5** — provisioning from pending pods, and consolidation —
  are now writing and deleting `Machine` objects, which experiment 19 showed
  works.

## Caveats

- **One Mac.** Two machines on one vmnet network. Nothing here says anything
  about two Macs, which is where mode 1 found vmnet rewriting source addresses.
- **ICMP, not a service.** The check is a ping between pods. Services across
  nodes go through kube-proxy, which is running but not exercised across the
  boundary here.
- **No NetworkPolicy** between machines, and no measurement of what the route
  agent costs when nodes come and go quickly.

## Reproduce

```sh
../18-node-image/build.sh
( cd ../../ferry-machined && go build -o ../bin/ferry-machined . )
./run.sh              # vmnet routing
KEEP=1 ./run.sh       # and leave it up
```
