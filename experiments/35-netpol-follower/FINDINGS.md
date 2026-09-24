# Experiment 35: NetworkPolicy served to joined Macs from the control plane

**Question.** A joined Mac ran its own ferry-netpol, which needed a `ferry-node-netpol` ClusterRole: list and watch on networkpolicies, pods, namespaces and nodes, for every kubelet credential. Can a joined Mac enforce policy with nothing beyond what a kubelet has?

**Change.**

- **Compile centrally.** The control plane's ferry-netpol compiles for every pod. It serves each node only its own pods' `/rules` and `/edge` on a mutual-TLS port (6444 plus the profile shift).
- **Authenticate with the kubelet certificate.** A caller must present a certificate that chains to the cluster CA, with `O=system:nodes` and `CN=system:node:<name>`, where the name is not empty. The check lives in `nodeauth/`, which ferry-registry's peer port shares.
- **Follow on a joined Mac.** A joined Mac runs ferry-netpol as a follower, with one HTTP/2 connection per local node's certificate. It serves the union of those rules on the same local socket, so ferry-cri and ferry-proxy are unchanged.
- **Remove the grant.** The ClusterRole and its binding are deleted at `ferry up` and at `ferry token create`.

**Measured.** A second profile was joined to the first on the same Mac, before (v0.6.0) and after. `policy.sh` gave the same results on the joined node as on the first node, which served as the control.

| median of 7 | before | after |
|---|--:|--:|
| policy applied → pod closed | 93 ms | 93 ms |
| policy applied → edge refuses | 46 ms | 45 ms |
| policy deleted → edge serves | 41 ms | 37 ms |

- **Scoping.** The joined node's certificate got only its own pod. The first node's certificate got only its two.
- **Authentication.** A request with no certificate, and one with another cluster's kubelet certificate, both failed the TLS handshake.
- **Upstream down.** With the control plane's ferry-netpol stopped, a `deny-all` was deleted. The joined pod and its edge stayed closed for 40 s. After the restart, the edge opened in 0.64 s and the pod in 0.73 s; the worst case is the follower's 5 s backoff. A follower restarted during the outage answers 503, and its consumers keep the rules they have.
- **Memory.** A joined Mac's ferry-netpol went from 32.8 to 28.3 MB, and it no longer grows with the cluster.

**Not verified.**

- Only one physical Mac was used, so both profiles share a LAN address.
- A pod that starts on a joined Mac while no rules can be fetched starts unfiltered, as it does on a single Mac with ferry-netpol down.
