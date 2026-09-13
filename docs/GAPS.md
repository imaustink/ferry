# What ferry does not do yet

Measured against minikube and kind, which are what people will compare it to.
Everything below was checked against a running cluster rather than assumed, and
re-checked after the work that closed most of the original list.

## Blocking for a beta

Nothing known. The four items that were here — NodePort going nowhere,
LoadBalancer stuck at `<pending>`, PersistentVolumeClaims sitting `Pending`, and
no way to run a locally built image — are done and verified.

That is a statement about this list, not a claim that ferry is finished. The
honest summary is that nothing currently *silently* fails; what is missing below
is missing visibly.

## Expected, and missing

- **Ingress.** minikube has an addon, kind documents a recipe. Neither exists
  here. A LoadBalancer now works, so an ingress controller has something to sit
  on, but nothing installs or configures one.
- **`metrics-server`.** `kubectl top` still returns *Metrics API not available*,
  so no HPA either.
- **Dashboard**, **registry**, and the rest of the addon ecosystem. minikube has
  around thirty `minikube addons`; ferry has none, and no mechanism for them.
- **Multiple clusters.** No profiles. One cluster per Mac, in `~/.ferry`.
- **Choosing the Kubernetes version.** Pinned to whatever `build-kubelet.sh`
  compiled — v1.34.0. minikube takes `--kubernetes-version`; ferry would need a
  rebuild, and the patches are version-sensitive.
- **Cluster upgrades.** No path from one version to another.
- **UDP and SCTP Services.** Rendered by kube-proxy, never carried: the in-pod
  rules and the host-side listeners are both TCP only.

## Silently accepted and ignored

One left, and it is the worst kind of gap because nothing reports it:

- **NetworkPolicy.** Objects are accepted and have no effect. There is no CNI
  plugin to enforce them — addressing is ferry's own switch, which does not
  filter. A cluster that accepts a deny-all policy and keeps forwarding
  everything is misleading in a way an absent feature is not.

## Architectural, not oversights

- **macOS on Apple silicon only.** kind and minikube run on Linux, Windows and
  Intel Macs. ferry's premise is `Virtualization.framework`.
- **One container runtime.** No containerd/CRI-O/docker choice; `ferry-cri` is
  the runtime.
- **No CNI choice.** Addressing is ferry's switch and vmnet; there is no plugin
  interface to swap.
- **128 pods, shared with the machine.** Every other VM on the Mac takes a slot.
- **An image is loaded per node**, not cluster-wide. minikube has the same
  property per profile.
- **A volume is local to one Mac.** The PersistentVolume says so through node
  affinity, and a pod that comes back is sent to the node holding its data —
  which is correct, and still not the same as network storage.

## Works, and worth saying so

`kubectl exec`, `attach`, `port-forward`, `logs`, `cp` · Services with
kube-proxy's own rules, including reject and hairpin · **NodePort** ·
**LoadBalancer**, with a real address rather than `<pending>` ·
**PersistentVolumeClaims**, provisioned and reclaimed · **`ferry image load`**,
so code built here runs here · cluster DNS · sidecars and init containers ·
ConfigMaps, Secrets, projected ServiceAccount tokens, emptyDir, hostPath,
subPath · resource limits and securityContext capabilities · RBAC and
ServiceAccount token auth, since the control plane is upstream · **more than one
node per Mac, and more than one Mac**, with pod-to-pod traffic keeping its source
address across machines.
