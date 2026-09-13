# What ferry does not do yet

Measured against minikube and kind, which are what people will compare it to.
Everything below was checked against a running cluster rather than assumed;
where ferry's behaviour is surprising rather than simply absent, that is said.

## Blocking for a beta

**No `NodePort` that goes anywhere.** kube-proxy renders the rules and the API
allocates a port, so a Service looks healthy and is not reachable:

```
NodePort allocated:   30719
reachable on the Mac: (nothing)
```

Silent failure is the worst kind. There are no nodes to land on, but the Mac is
the node, and something on the host should listen. Until then it should at least
be refused loudly.

**No `LoadBalancer`.** `EXTERNAL-IP` stays `<pending>` forever. minikube has
`minikube tunnel`, kind has cloud-provider-kind. Pod IPs are already routable
from the Mac, so this is closer than it looks.

**No dynamic volume provisioning.** There is no StorageClass, so a bare PVC sits
`Pending` and any Helm chart with persistence stops there. minikube ships
`storage-provisioner` as a default addon, kind ships local-path-provisioner.
`hostPath` volumes do work, which is the substrate a provisioner needs.

**No way to load a locally built image.** `minikube image load` and `kind load
docker-image` are how people iterate on their own code, and ferry has no
equivalent — everything must come from a registry. For a tool aimed at local
development this is arguably the biggest gap on the list.

## Expected, and missing

- **Ingress.** minikube has an addon, kind documents a recipe. Neither exists here.
- **`metrics-server`.** `kubectl top` returns *Metrics API not available*, so no
  HPA either.
- **Dashboard**, **registry**, and the rest of the addon ecosystem. minikube has
  about thirty `minikube addons`; ferry has none, and no mechanism for them.
- **Multiple clusters.** No profiles. One cluster per Mac, in `~/.ferry`.
- **Choosing the Kubernetes version.** Pinned to whatever `build-kubelet.sh`
  compiled — v1.34.0. minikube takes `--kubernetes-version`; ferry would need a
  rebuild, and the patches are version-sensitive.
- **Cluster upgrades.** No path from one version to another.

## Architectural, not oversights

- **One node.** The Mac is the node. kind's whole premise is multi-node clusters
  in containers, so anything testing scheduling across nodes, topology spread,
  or node affinity has no home here. This is the deepest difference and not
  something to fix casually — every "node" would be another VM, and then ferry is
  the thing it was built not to be.
- **macOS on Apple silicon only.** kind and minikube run on Linux, Windows and
  Intel Macs. ferry's premise is `Virtualization.framework`.
- **One container runtime.** No containerd/CRI-O/docker choice; `ferry-cri` is
  the runtime.
- **No CNI choice, and so no NetworkPolicy.** Addressing is vmnet; there is no
  CNI plugin to swap. NetworkPolicy objects will be accepted and ignored, which
  is its own silent failure.
- **128 pods, shared with the machine.** Every other VM on the Mac takes a slot.

## Works, and worth knowing it works

Listed because several are the ones people assume a tool like this will not have:

`kubectl exec`, `attach`, `port-forward`, `logs`, `cp` · Services with
kube-proxy's own rules, including reject and hairpin · cluster DNS · sidecars and
init containers · ConfigMaps, Secrets, projected ServiceAccount tokens, emptyDir,
hostPath, subPath · resource limits and securityContext capabilities · RBAC and
ServiceAccount token auth, since the control plane is upstream.
