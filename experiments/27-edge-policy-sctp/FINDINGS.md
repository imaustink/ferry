# Experiment 27: NetworkPolicy at the edge, low ports without root, SCTP

**Question.** GAPS.md listed three networking limits:

- ingress policy does not filter traffic from the node;
- a LoadBalancer below port 1024 needs root;
- SCTP is missing in both ferry-proxy and the guest kernel.

For each one, is the constraint real, and where does it bite?

**Method.** A private cluster from a worktree, uid 501, no sudo, with two nodes on one Mac. The scripts here are the whole experiment:

| script | what it does |
|---|---|
| `policy.sh <lan-ip> <node-port>` | applies one policy after another to a pod behind a LoadBalancer and a NodePort, and tries every way in |
| `policy-n2.sh` | the same against a pod on the second node |
| `ingress-policy.sh` | ingress-nginx under `deny-all`, then a named-port `ipBlock` |
| `sctp.sh <server-node> <client-node>` | SCTP to a pod IP and to a ClusterIP, on one node and across two |
| `bench/` | proxy latency and throughput, alternating the old and new ferry-proxy |

## 1. External clients bypassed every policy

`ferry-netpol` accepted two things before any policy rule:

- any source outside the cluster CIDR;
- every node's `.1` gateway.

`ferry-proxy` dials pods from the Mac's own `.1`. So every NodePort, LoadBalancer and hostPort client arrived from an exempt address.

Before the change, with `deny-all` in place, the LoadBalancer still served the LAN. A pod could also get in by dialling `<gateway>:<nodeport>`, because ferry-proxy re-originated the connection from the exempt address.

**The fix is to enforce at the edge, where the client's address is still known.**

- `ferry-netpol` serves the resolved ingress rules as JSON at `/edge`.
- Before dialling, `ferry-proxy` checks the client's `RemoteAddr` against the chosen pod's rules, and refuses with a reset.
- Inside the guest, only loopback, established traffic and the pod's own node are exempt. The all-nodes accept and the non-cluster accept are gone.
- `ipBlock.except`, `endPort` and named ports are now compiled. Named ports used to go to nft, which looked them up in `/etc/services`.

The alternative was to exempt the node only on each pod's probe ports. That was rejected: it would break the API server reaching admission webhooks (ingress-nginx's 8443 has no probe), `ferry image build` reaching buildkitd, and `curl` from the Mac to a pod.

After the change (`policy.sh`):

| policy | LAN:80 | localhost:80 | node port | pod → node port | pod Ready |
|---|---|---|---|---|---|
| none | served | served | served | served | yes |
| `deny-all` | refused | refused | refused | refused | yes, 0 restarts over 24 s |
| `ipBlock <lan>/32`, port 80 | served | refused | served | refused | yes |
| `ipBlock 0.0.0.0/0 except <lan>/32` | refused | served | refused | served | yes |
| `podSelector` naming the client pod | refused | refused | refused | served | yes |
| a rule for port 81 only | refused | refused | refused | refused | yes |

- A pod on the second node gave the same results.
- With ingress-nginx under `deny-all`, the controller stays Ready and its admission webhook still answers the API server; the LoadBalancer is refused.
- An `ipBlock` on the named port `http` lets the LAN back in.
- `kubectl top` keeps working.

**Cost.** The check is an atomic snapshot lookup: 6–18 ns and 0 allocations per accept. Proxy p50 was 320, 328, 323 and 330 µs before and 333 and 332 µs after, alternating. Throughput was 5.4–6.8 GB/s both ways. Both differences are within the noise on a busy Mac.

## 2. Ports below 1024 do not need root on macOS

This was measured with Python and Go as uid 501 on macOS 26.6.2:

| bind | 80 / 443, TCP and UDP |
|---|---|
| `0.0.0.0` or `::` | allowed |
| `127.0.0.1` or the LAN IP | `EACCES` |

A connection accepted on the wildcard reports the address it arrived on in `LocalAddr()`. So a LoadBalancer now binds the wildcard and answers only at the LAN IP and loopback. UDP filters on the destination address (`IP_RECVDSTADDR`) and replies from that address.

- ingress-nginx gets `EXTERNAL-IP` = the LAN address on 80 and 443. `LAN:80`, `localhost:80` and `localhost:443` all return 200.
- A UDP LoadBalancer on 853 answers on the LAN and on loopback.
- **UDP 53 is held by a root process on this Mac**, so it cannot be served. That is reported as `PortInUse`.
- **AirPlay Receiver holds `*:5000`.** When something else holds the wildcard, a port at or above 1024 falls back to binding each address and records `PortShared`. Ports 5000 on the LAN, 127.0.0.1 and localhost all answer beside AirPlay.

## 3. SCTP: the kernel already has it; macOS does not

The guest kernel's IKCONFIG has:

- `CONFIG_IP_SCTP=y`
- `CONFIG_NF_CT_PROTO_SCTP=y`
- `CONFIG_NETFILTER_XT_MATCH_SCTP=y`

GAPS.md was wrong about the kernel.

Tested with `sctp.sh`, python3 `socket.IPPROTO_SCTP` in `python:3.13-alpine`:

| path | before | after |
|---|---|---|
| across nodes, pod IP and ClusterIP | ~1 ms, client address preserved | unchanged |
| same node, pod IP and ClusterIP | timed out | 0.5–0.6 ms |

On one node, eth0 is vmnet, and vmnet drops IP protocol 132. A netdev egress rule in the pod now sends SCTP bound for the cluster out of eth1, the switch, which carries any Ethernet frame.

The first association to a new peer waits one 3 s INIT retransmit while eth1 resolves the neighbour. After that it takes 0.5–0.6 ms. With the rule in place, TCP ran at 4.0–5.7 GB/s, against 4.1–5.7 without it.

**There is no unprivileged host edge.** On macOS:

- `socket(AF_INET, SOCK_STREAM, IPPROTO_SCTP)` gives `EPROTONOSUPPORT`;
- a raw protocol-132 socket gives `EPERM`;
- `/dev/bpf*` is root-only.

So NodePort, LoadBalancer and hostPort cannot carry SCTP. ferry-proxy now records `SCTPNotServed` on the Service instead of skipping it silently.

## Found on the way

- **A hostPort in front of a different containerPort was dialled at the hostPort.** It is now dialled at the containerPort: 5001→80 returns 200, where it was reset before.
- **A NodePort for a pod on another node of the same Mac forwarded to its own listener**, until it ran out of file descriptors (858 MB resident, empty replies). It now dials the pod directly.
- **A node re-added under an old name kept its old podCIDR**, so ferry-netpol computed the wrong gateway and dropped every probe. The node's address is now derived from the pod's own IP.

## Not verified

- No second LAN host was used. "LAN" means the Mac connecting to its own LAN address.
- A cross-Mac NodePort forward is checked against the forwarding Mac's address, as `externalTrafficPolicy: Cluster` would be.
