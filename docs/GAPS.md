# What ferry does not do yet

Measured against minikube and kind, which are what people will compare it to.
Everything below was checked against a running two-node cluster rather than
assumed, and re-checked after the work that closed most of the original list.

The shape of this document has changed since it was first written. Then, the
interesting part was a list of things that did not work. Now most of them do,
and the interesting part is the handful of places where ferry accepts something
and does not quite honour it.

## Blocking for a beta

Nothing known.

Everything that was here — NodePort going nowhere, LoadBalancer stuck at
`<pending>`, PersistentVolumeClaims sitting `Pending`, no way to run a locally
built image, NetworkPolicy silently ignored, one cluster per Mac — is done, and
each was verified on a live cluster rather than in a unit test.

That is a statement about this list, not a claim that ferry is finished.

## Accepted, and only partly honoured

These are the ones that matter most, because nothing reports them.

- **A NetworkPolicy does not reach pods that are already running.** Rules are
  programmed when a pod starts. Apply a `deny-all` to a namespace whose pods are
  already up and traffic keeps flowing — measured at 15s, 30s and 60s, with no
  change. Delete the pod and the replacement comes up correctly isolated, and
  *deleting* a policy does take effect on a running pod. So the enforcement is
  real and the reconcile loop is one-directional: it can take rules away from a
  running pod but not give them to one. Until that is fixed, a policy is only
  trustworthy for workloads started after it.

- **`kubectl top nodes` returns "metrics not available yet"**, while
  `kubectl top pods` works. The kubelet serves the node series but reports
  `node_cpu_usage_seconds_total 0` on both nodes, and metrics-server drops a
  node sample whose cumulative CPU is zero. Pod-level CPU and memory are real.
  This is ferry's darwin kubelet not accounting for whole-machine CPU, not a
  metrics-server problem.

- **A LoadBalancer on a privileged port needs `ferry-proxy` running as root.**
  Ports at or above 1024 are served unprivileged. Below that — which includes
  every ingress controller's 80 and 443 — the listener fails and the Service
  keeps `<pending>` for its external address, with the reason in
  `ferry-proxy.log` rather than on the Service. The NodePorts for the same
  Service are served either way, which is how the ingress test below passes.

## Expected, and missing

- **SCTP Services.** UDP is carried now, end to end. SCTP is still rendered by
  kube-proxy and never carried.
- **Choosing the Kubernetes version.** `build-kubelet.sh` honours
  `K8S_VERSION`, so the knob exists, but ferry does not expose it, nothing
  verifies another version builds, and the patches are version-sensitive.
  minikube takes `--kubernetes-version` and means it.
- **Cluster upgrades.** No path from one version to another.
- **Dashboard**, **registry**, and the rest of the addon ecosystem. The addon
  mechanism now exists — `ferry addons list|enable|disable`, reading
  `addons/<name>/` — and carries two. minikube has around thirty.

## Architectural, not oversights

- **macOS on Apple silicon only.** kind and minikube run on Linux, Windows and
  Intel Macs. ferry's premise is `Virtualization.framework`.
- **One container runtime.** No containerd/CRI-O/docker choice; `ferry-cri` is
  the runtime.
- **128 pods, shared with the machine.** Every other VM on the Mac takes a slot.
- **An image is loaded per node**, not cluster-wide. minikube has the same
  property per profile.
- **A volume is local to one Mac.** The PersistentVolume says so through node
  affinity, and a pod that comes back is sent to the node holding its data —
  which is correct, and still not the same as network storage.

## Works, and worth saying so

Verified on the running cluster while writing this:

- **Ingress.** `ferry addons enable ingress-nginx`, an `Ingress` with a host
  rule, and `curl -H 'Host: web.ferry.test' http://<mac>:30100/` answers
  HTTP 200 from the backend. This was previously listed as absent.
- **`kubectl top pods`**, and therefore the metrics API, without
  `FERRY_HOST_CLUSTER_IPS=1`. Putting the Mac properly on the pod network made
  the aggregated API reachable from the API server; the note in
  `addons/metrics-server/NOTES` still says otherwise and is now stale.
- **Real CNI plugins**, on the Mac and inside the pod VM, through libcni's own
  `invoke.Exec` seam — so addressing is no longer ferry's switch alone.
- **GPU.** Both nodes advertise `ferry.dev/gpu: 1`, the scheduler rations it,
  and a pod that asks gets Metal work done on the Mac's own GPU.
- **More than one cluster at a time.** Profiles derive from the checkout, so a
  second worktree runs a second cluster with its own state, ports and pod CIDR.
  Confirmed by a second `ferry-cri` running from a worktree while this one ran.
- **More than one node per Mac, and more than one Mac**, with pod-to-pod traffic
  keeping its source address across machines.
- **NetworkPolicy**, subject to the caveat above.
- **NodePort**, **LoadBalancer** with a real address above port 1024,
  **PersistentVolumeClaims** provisioned and reclaimed, **`ferry image load`**,
  **UDP Services**.
- `kubectl exec`, `attach`, `port-forward`, `logs`, `cp` · Services with
  kube-proxy's own rules, including reject and hairpin · cluster DNS · sidecars
  and init containers · ConfigMaps, Secrets, projected ServiceAccount tokens,
  emptyDir, hostPath, subPath · resource limits and securityContext
  capabilities · RBAC and ServiceAccount token auth, since the control plane is
  upstream.
