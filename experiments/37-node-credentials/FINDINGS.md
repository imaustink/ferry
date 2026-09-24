# Experiment 37: a certificate for every node, and no `ferry:system-nodes`

**Question.** `control-plane/up.sh` bound the whole `system:node` ClusterRole to the `system:nodes` group. That let every kubelet credential list pods and Secrets in every namespace. Why was it there, and what breaks without it?

**Why it was there.** It arrived with experiment 02. Only one thing actually needed it: `ferry node add` ran every added kubelet on the *first* node's certificate. With the binding deleted by hand, a node added that way went `Ready=Unknown` in 46 s, with "can only access node lease with the same name as the requesting node".

**Change.**

- **A certificate per node.** `ferry node add` signs a client certificate for each node: `CN=system:node:<name>`, `O=system:nodes`. It is kept under `pki/nodes/`. Restarts and `ferry upgrade node` reuse it.
- **Joined Macs.** A joined Mac already got its own certificate, through the bootstrap token and CSR.
- **Migration.** On an existing cluster, `ferry up` restarts only the kubelet of an added node that is still on the shared certificate. Its runtime and pods stay up.
- **The binding.** It is deleted. `NodeRestriction` admission is enabled.
- **A narrower grant.** Upstream's read-only `system:node-proxier` (Nodes, Services, EndpointSlices) is bound as `ferry-node-proxier`. Without it, mode 2's route agent can read only its own Node. Two machines then came up Ready with no routes to each other's pods; with it, both had routes within 4 s.

**Measured** on four nodes: one from `ferry up`, two from `ferry node add`, and one on a second profile joined to it.

| check | before | after |
|---|---|---|
| `can-i list pods -A` and `list secrets -A`, each node impersonated and with its own kubeconfig | yes | **no, 16 of 16** |
| a node changing another node | allowed | "not allowed to modify node" |
| a node deleting a pod on another node | allowed | "can only delete pods with spec.nodeName set to itself" |
| a node patching another node's status | 200 | 403 (its own: 200) |

- **Still working:**
  - All nodes are Ready, and a pod runs on each.
  - `exec`, `logs`, `port-forward`, DNS and ClusterIPs work from every node.
  - PVCs bind on the control-plane Mac's three nodes.
  - NetworkPolicy is enforced on the joined node: a median of 115 ms in the pod and 65 ms at the edge.
  - The GPU is advertised on the first node and on the joined one.
- **Migration:** an added node on the shared certificate stayed Ready through `ferry upgrade apply v1.35.8`, and came back on a certificate of its own.
- **Cost:** signing takes 82 ms once per node, and checking the certificate takes 38 ms on each later start. Nothing on a pod's or a packet's path changed.

**Found on the way:**

- A joined Mac's pods were given 10.244.0.2 for DNS whatever the cluster CIDR. It is now derived from the CIDR.
- On a rejoin, the GPU advertisement could get a 404 before the Node had registered. It now retries for up to 30 s.

**Not caused by this change.** Each of these was checked with the binding put back:

- PVCs on a joined Mac never bind: its ferry-storage is `forbidden` from listing PVs and PVCs.
- A hostPort on an added node is not served at the edge.
- Added nodes do not advertise `ferry.dev/gpu`.
