# What ferry does not do yet

This is measured against minikube and kind, which are what people will compare ferry to. Everything below was checked against a running cluster rather than assumed. Each claim links to the experiment that measured it.

This revision closed most of what the last one listed. It also found that three of those entries were wrong about the cause, and one was wrong about the risk. Those corrections come first.

## Corrections

- **SCTP was never missing from the guest kernel.** The kernel ferry boots has `CONFIG_IP_SCTP=y`, `CONFIG_NF_CT_PROTO_SCTP=y` and the SCTP match, and did before. What stopped SCTP was that vmnet drops IP protocol 132 between two pods on one node, and that macOS has no SCTP at all. See [experiment 27](../experiments/27-edge-policy-sctp/FINDINGS.md).
- **A LoadBalancer below 1024 never needed root.** macOS refuses a low port to an unprivileged process only when it binds a specific address; the wildcard is allowed. Binding the wildcard and answering only at the LAN address and loopback is all it took. See experiment 27.
- **A crash never restarted the whole pod because Containerization refuses to restart a container.** The kubelet never restarts a container; it creates a new one with a new ID. The pod was rebuilt because each container was its own disk, and a running VM cannot take another disk. See [experiment 31](../experiments/31-restart-in-place/FINDINGS.md).
- **"Ingress policies do not filter traffic from the node" understated the risk.** ferry-proxy dialled pods from the node's own address, and ingress policy let the node through. So every NodePort, LoadBalancer and hostPort client bypassed NetworkPolicy entirely: a `deny-all` stopped other pods and nothing from the internet. Anything from outside the cluster CIDR was accepted as well, which made `ipBlock` meaningless. Policy is now enforced at the edge, where the client's address is still known. See experiment 27.

The last revision's lesson holds: two observations can be consistent with a theory that is still wrong. Every item above was re-measured before it was changed.

## Closed in this revision

| was | now | measured in |
|---|---|---|
| NodePort, LoadBalancer and hostPort clients bypass NetworkPolicy | ferry-proxy checks each client against the chosen pod's rules before dialling (6–18 ns, 0 allocations per accept); `ipBlock`, `except`, `endPort` and named ports are compiled; joined Macs enforce policy too | [27](../experiments/27-edge-policy-sctp/FINDINGS.md), [34](../experiments/34-join-policy/) |
| a LoadBalancer below 1024 needs root | ingress-nginx gets the LAN address on 80 and 443 unprivileged; `localhost` reaches LoadBalancers | 27 |
| SCTP Services absent | SCTP to a pod and to a ClusterIP works on one node (0.5–0.6 ms) and across nodes (~1 ms) | 27 |
| a crash in a multi-container pod restarts the pod | the container restarts inside the running VM in ~45 ms, with the same IP and sibling PIDs; a container of an image the pod already runs can join after boot, `kubectl debug` included; the ~22-container ceiling per pod is gone | [31](../experiments/31-restart-in-place/FINDINGS.md) |
| an idle pod costs 226 MiB; maxPods 72 on 32 GiB | **133 MiB**, flat at 20 and 60 pods; maxPods 110 from 32 GiB up, 61 on 16 GiB | [32](../experiments/32-pod-memory-footprint/FINDINGS.md) |
| no zero-downtime control plane upgrade | 0 failed requests under a 50 ms probe; the slowest held request took 1.5 s | [28](../experiments/28-control-plane-upgrades/FINDINGS.md) |
| a minor bump on a running cluster only reasoned about | v1.34 → v1.35 → v1.36 applied live, with the node roll and a rollback | 28 |
| every node on one Mac moves together | each node runs its kubelet from its own version directory | 28 |
| an image is loaded per node | a loaded or built image reaches every node on the Mac, every machine, and other Macs through their registries, with mutual TLS | [33](../experiments/33-cluster-images-and-volumes/FINDINGS.md) |
| `chown` refused, and no real ReadWriteOnce, on mode 2 volumes | `storageClassName: ferry-local-block` is an ext4 disk attached to the machine over USB: ownership is kept, pods on one machine share it, and it moves between machines | 33 |
| two addons | ten, each enabled, used and disabled on a cluster: metrics-server, ingress-nginx, registry, dashboard, headlamp, cert-manager, gateway-api, envoy-gateway, kube-state-metrics, prometheus | [addons/README.md](../addons/README.md) |
| `medium: Memory` is disk | a tmpfs in the pod VM, sized from `sizeLimit` or the pod limit, charged to the container's cgroup, and carried over any VM replacement | [30](../experiments/30-volumes-and-logs/FINDINGS.md) |
| a late subPath is `0755 root` | a late subPath gets the volume root's mode, as on Linux | 30 |
| `kubectl logs --previous` fails after each crash | 0 of 932 polls failed, against 255 of 921 before. The window was 12–32 s, not "a few seconds". | 30 |

**Found and fixed on the way:**

- **An etcd restore did not bump the revision**, so every watcher silently missed it.
- **`ferry down` killed every profile's ferry-proxy.**
- **A NodePort for a pod on another node of the same Mac forwarded to itself** until it ran out of file descriptors.
- **A hostPort in front of a different containerPort was dialled at the hostPort.**
- **Exec probes never ran:** ExecSync was not implemented.
- **Containers were never asked to stop:** they got SIGKILL at once.
- **`ferry node add` reused a stale podCIDR.**
- **CoreDNS could lose its reserved address.**
- **Nothing refused an unsafe upgrade:** the node skew check only warned, only looked at local nodes, and `apply` also moved the kubelet.
- **ferry-proxyd was never upgraded.**
- **A rollback across a minor kept the newer data.**
- **Several kubelet build seams were skipped silently** when their upstream file moved.

## Expected, and missing

- **SCTP at the edge.** A NodePort, LoadBalancer or hostPort cannot carry SCTP:
  - macOS answers an SCTP socket with `EPROTONOSUPPORT` and a raw protocol-132 socket with `EPERM`;
  - `/dev/bpf*` is root-only.

  The Service now records `SCTPNotServed` rather than silently getting no listener. The first SCTP association to a new peer on the same node waits one 3 s INIT retransmit while the switch resolves the neighbour.
- **RWX `chown`, and volumes that span Macs.** A ReadWriteMany claim, and the default `ferry-local` class in mode 2, are virtiofs directories served as the Mac user. `chown` there does not fail, but it is not kept: each caller sees its own uid as the owner.

  A spike with an NFSv3 server running as the user mounted from both kinds of pod and kept `chown` in an xattr, at virtiofs speed. Before it can ship it needs three things:
  - a server that passes the caller's identity through for permission checks;
  - real syncs;
  - scoped exports.

  See experiment 33.
- **About twenty fewer addons than minikube.** The mechanism now makes adding one cheap: pinned remote sources, kustomize, hooks, readiness checks and an arm64 check. What cannot come over is anything that is a node agent: node-exporter, CSI node plugins, eBPF tools, GPU device plugins. A pod here is its own VM, with no host PID, network or `/proc` to share.
- **A second physical Mac is simulated, not measured.** Joined-Mac policy, peer registries and upgrades were each run against a second profile on the same Mac, which shares its loopback address and its LAN IP.

## Known, and deliberate

- **A container joins a running pod only with an image the pod already runs.** Images are disks attached at boot, and the pod kernel is given no USB controller for a late one. A regular container with any other image has the pod recreated around it; a `kubectl debug` container with one is refused, so debugging never restarts a pod. A block volume that arrives after boot costs one VM rebuild. `kubectl debug --target` does not join the target's PID namespace.
- **The pod's own node is exempt from its ingress policy,** for the traffic the node originates: kubelet probes, the API server reaching webhooks, `curl` from the Mac. Cilium and Calico strike the same bargain. Traffic that ferry-proxy forwards in from outside is checked against the client's own address. Written down in [NETWORK-POLICY.md](NETWORK-POLICY.md).
- **A node reads the cluster's shape, and changes only its own objects.** Every node now has a kubelet certificate of its own (`ferry node add` signs one; a joined Mac's comes from its CSR), `ferry:system-nodes` is gone, and NodeRestriction is on. As any node, `can-i list pods -A` and `list secrets -A` are `no`, and patching another node or deleting its pods is refused. What every node can still read is the Node list, Services and EndpointSlices, through upstream's `system:node-proxier`: a joined Mac renders its own Service rules from them and a machine routes to the other machines' pods from the Node list. See [experiment 37](../experiments/37-node-credentials/).
- **UDP 53 cannot be a LoadBalancer on this Mac:** a root process already holds it. It is reported on the Service as `PortInUse`. TCP 80 and 443 and UDP 853 were served. A port that another program holds on the wildcard, such as AirPlay's 5000, is served beside it on each address.
- **Memory emptyDirs are bounded by ENOSPC, not eviction.** They are lost if the VM crashes outright, and a carried tmpfs loses its sticky bit (1777 → 0777) through vminitd's extractor.
- **A block claim's synced writes are slower:** about 0.5 ms for a 4 KiB write, against 0.15 ms on virtiofs. That is why `ferry-local-block` is a class of its own rather than the default.
- **Read-ahead is a trade between memory and throughput, set per pod.** The guest agent's disk stays at 128 KiB, and that is the memory saving. Image and volume disks default to 1 MiB, which restores 87-100% of the throughput of reading a large file 64 KiB at a time (Mac-cached 4.8 → 14.4 GB/s; cold 3.0 → 5.1). It costs 0-4 MiB per pod for alpine, nginx and python. A pod with one large binary pays by the window: node is 17 MiB more at 1 MiB and would be 48 MiB more at 8 MiB. Raise it with `FERRY_POD_READAHEAD_KB` or `ferry.dev/read-ahead-kb`. Setting it adds about 3-5 ms to a boot ([experiment 36](../experiments/32-pod-memory-footprint/FINDINGS.md#read-ahead-on-the-pods-own-disks-experiment-36)).
- **A control plane rollback that restores a snapshot is an outage** (2.8 s measured), and it loses what was written since the snapshot. It says when the snapshot was taken and asks first.

## Architectural, not oversights

- **macOS on Apple silicon only.** kind and minikube run on Linux, Windows and Intel Macs. ferry's premise is `Virtualization.framework`, and Containerization is arm64 only.
- **One container runtime.** ferry-cri is a standard CRI, and the kubelet is pointed at it through a socket and nothing else. But no other runtime runs Linux pods on darwin behind a CRI socket.
- **The 128-VM ceiling is shared** with every other VM on the Mac. At 133 MiB a pod, memory no longer binds first on a 32 GiB Mac. What is left of the 133 MiB cannot be given back once touched: the balloon returns nothing, even under pressure (experiments 14 and 32). The rest is:
  - the guest agent's page cache, about 45 MiB;
  - the kernel image: about 21 MiB in the guest, plus 19.5 MiB the framework keeps on the host;
  - slab 12 MiB, page map 8 MiB, and the framework itself about 8 MiB.

  Mode 2 is the dense alternative that is already built: one kernel per machine, about 17 MiB a container.
- **A volume is local to one Mac.** The PersistentVolume says so through node affinity, and a pod that comes back is sent to the node holding its data. Images now move between Macs; volumes do not.
- **A ReadWriteOnce volume is mounted by one pod at a time in mode 1**, where Kubernetes allows every pod on the node. ferry's pods are each a machine, so this is ReadWriteOncePod, and a rolling update gets there a little slower. For several pods on one Mac, ask for ReadWriteMany. In mode 2, `ferry-local-block` gives real per-node ReadWriteOnce.
- **An emptyDir or a block claim is an ext4 image**, so its contents are not browsable from Finder. The exception is a memory emptyDir. An emptyDir is sparse and at most 16 GiB, since CRI does not carry `sizeLimit`; the kubelet still enforces `sizeLimit` against what the image holds.
- **There is no zero-downtime etcd.** A control plane switch keeps etcd running whenever its version is unchanged, which is every minor from v1.34 to v1.37. A minor that pairs with a new etcd would stop it for the switch; none has been run.
- **A minor bump is a port of `patches/`.** The build now refuses to go on when a seam's file has moved or a constructor's signature has changed, and shows the diff. The port is still done by hand.

## Works, and worth saying so

This was verified on a running cluster:

- **NetworkPolicy**, on the same node, across nodes and at the edge.
  - With `deny-all`, a pod refuses its neighbour, a pod on another node, the LAN, `localhost` and its own NodePort, and stays Ready.
  - `ipBlock` with `except` admits exactly the addresses it names.
- **Restarts in place.** A crashing container restarts in about 45 ms, and its siblings keep running. Exec probes, graceful stop, termination messages, native sidecars and `kubectl debug` all work.
- **Upgrades** without a failed request, per-node versions, and a live minor bump with rollback. See [UPGRADES.md](UPGRADES.md).
- **Ingress** and **Gateway API** on ports 80 and 443, with no root.
- **`kubectl top pods`** and **`kubectl top nodes`**, through the metrics-server addon.
- **A registry you can push to**, with pods pulling from `localhost:5001`, and every loaded image available cluster-wide.
- **Real CNI plugins** on the Mac and inside the pod VM, portmap included.
- **GPU.** Nodes advertise `ferry.dev/gpu: 1`, the scheduler rations it, and a pod that asks for it gets Metal work done on the Mac's own GPU.
- **More than one cluster at a time**, **more than one node per Mac**, and **more than one Mac**, with pod-to-pod traffic keeping its source address across machines.
- **Services and networking:**
  - NodePort, LoadBalancer, hostPort (including a different containerPort), and TCP, UDP and in-cluster SCTP Services;
  - kube-proxy's own rules, including reject and hairpin;
  - cluster DNS.
- **kubectl:** `exec`, `attach`, `port-forward`, `logs` (including `--previous`) and `cp`.
- **Pods:**
  - sidecars and init containers;
  - ConfigMaps, Secrets and projected ServiceAccount tokens;
  - emptyDir on disk or in memory, hostPath and subPath;
  - resource limits and securityContext capabilities.
- **Volumes and images:** PersistentVolumeClaims provisioned and reclaimed, and `ferry image load` and `ferry image build`.
- **Access control:** RBAC and ServiceAccount token auth, since the control plane is upstream.
