# Addons

Manifests ferry can apply on request, pinned to versions that have been run
here.

```sh
ferry addons list                    # what there is, and what is on
ferry addons enable registry         # apply, wait until it works, print NOTES
ferry addons disable registry        # delete exactly what enable applied
ferry addons images cert-manager     # does every image have a linux/arm64 build
```

`enable` takes several names and `--no-wait`. Enabling an addon that is already
on applies it again, which is how one is upgraded after the repo moves on.

## What there is

Every row was enabled on a running cluster, used for what it is for, and
disabled again with nothing left behind. Memory is each pod VM's
`phys_footprint` on the Mac, idle after enabling -- a pod here is a virtual
machine, so the pod count is the cost.

| addon | version | pods | Mac memory | verified by |
|---|---|--:|--:|---|
| metrics-server | v0.7.2 | 1 | 318 MiB | `kubectl top nodes` answering |
| ingress-nginx | v1.11.3 | 1 | 359 MiB | an Ingress with a host rule answering 200 through the node port |
| registry | 3.1.1 | 1 | 306 MiB | `crane copy` to localhost:5001, a pod pulling `localhost:5001/…` and running it; images still there after the pod and the cluster were restarted |
| dashboard | v2.7.0 | 2 | 549 MiB | port-forward, the dashboard's own API listing kube-system's pods with the token, 401 without |
| headlamp | v0.45.0 | 1 | 373 MiB | port-forward, namespaces listed through Headlamp with the token, 403 without |
| cert-manager | v1.21.2 | 3 | 903 MiB | the webhook denying an invalid Issuer; a self-signed ClusterIssuer issuing a Certificate in 1 s |
| gateway-api | v1.6.2 | 0 | 0 | the CRDs established |
| envoy-gateway | v1.9.1 | 1, +1 per Gateway | 435 MiB, +464 MiB | a Gateway programmed at the Mac's LAN address in 12 s; an HTTPRoute answering 200 for its host and 404 for another |
| kube-state-metrics | v2.20.0 | 1 | 306 MiB | scraped by the prometheus addon; enabled again with the network cut, from cache |
| prometheus | v3.14.0 | 1 | 419 MiB | every target up: API server, kubelet, the kubelet's resource metrics, kube-state-metrics |

The scripts that did it are in [experiments/29-addons](../experiments/29-addons/).
`podmem` finds a pod's VM as the Virtualization process holding that pod's
kubelet directory open, which stays right with other clusters' VMs on the same
Mac; counting VMs before and after an enable did not, and reported six for the
two-pod dashboard. A pod doing little is about 300 MiB (CoreDNS: 310), above
the 226 MiB of an idle VM by what the workload holds.

Leaner is chosen over complete wherever the two differ, because of that last
column. The dashboard is 2.7.0, the last release with a plain manifest -- 7.x is
five pods behind Kong -- and the one minikube still ships; the project itself
was retired in 2026 in favour of Headlamp, which is one pod. The prometheus addon
is one Prometheus, not kube-prometheus's dozen pods.

Some things are absent because they cannot work here rather than because nobody
wrote them. Anything that is a DaemonSet reading the node's kernel --
node-exporter, CSI node plugins, eBPF agents, a CNI -- expects `hostPID`,
`hostNetwork` and a Linux host under `hostPath`. A ferry node is a Mac, and each
pod gets its own VM whatever it asks for.

## What an addon is

A directory holding ordinary Kubernetes manifests and an `addon.conf`:

```
description=image registry at localhost:5001, backed by a PersistentVolume
version=3.1.1
namespace=registry
requires=gateway-api                          # enabled first, if not already
source=https://…/install.yaml <sha256> [name] # fetched, checked, cached; repeatable
server_side=true                              # kubectl apply --server-side
check=curl -fsS http://localhost:5001/v2/     # retried until it passes; repeatable
timeout=300                                   # for rollouts and checks together
```

Beside it, all optional:

- **`*.yaml`**, applied after any sources. `__CLUSTER_DNS__`, `__NODE_NAME__` and
  `__LOAD_BALANCER_IP__` are substituted in these, not in fetched files.
- **`kustomization.yaml`**, which makes the whole directory -- fetched files
  included, under their names -- a kustomize build. It is how an upstream
  manifest gets pinned or patched without being copied: headlamp's `:latest`
  becomes a tag, and envoy-gateway's bundled copy of the Gateway API CRDs is
  dropped so the gateway-api addon alone owns them.
- **`NOTES`**, printed after enabling.
- **`pre-enable`, `post-enable`, `pre-disable`, `post-disable`**, executables
  run with `KUBECONFIG` set, and `ADDON_DIR` and `ADDON_STATE` naming the addon
  and its state directory. The dashboard's writes its login token to a file
  there rather than to the terminal; cert-manager's deletes the leader-election
  leases it made in kube-system, which no manifest lists.

Enabling applies, then waits: every Deployment, StatefulSet and DaemonSet has to
finish rolling out, then every `check` has to pass. A check says what "works"
means for that addon, which a Ready pod usually does not: metrics-server's is
the aggregated API answering, cert-manager's is a server-side dry run through
its webhook. When it gives up it prints the pods, what each is waiting on --
this is where an image with no arm64 build shows up -- and the recent warnings.
When kubectl refuses the manifest, its error is printed.

What was applied is recorded in `$FERRY_HOME/addons/<name>/`. `list` reads that
record -- it used to guess from a namespace or a kube-system Deployment named
after the addon, which would call dashboard, prometheus and gateway-api off
while they were on -- and `disable`
deletes what the record holds, so it removes what was applied even after the
repo's copy has changed. An addon enabled before there were records is disabled
by deleting what enabling it now would create.

## Remote sources, and offline

Large upstream manifests are fetched rather than vendored: cert-manager is 14
thousand lines, Envoy Gateway 63 thousand. Each is pinned by sha256; a file that
has changed upstream under the same URL is refused, not applied. Fetched files
are kept in `$FERRY_HOME/cache/addons/` under their hash (6 MiB for everything
here), and the cache is consulted first, so an addon enabled once enables again
with no network. `FERRY_ADDON_CACHE` moves it.

`tests/addons-test.sh` checks all of this without a cluster.

## The registry

`localhost:5001` is the same registry from both sides: a push from the Mac, and
a pod's image reference, because a pod's image is pulled by ferry-cri on the
Mac. ferry-cri speaks plain HTTP to loopback and to the Mac's own addresses;
other plain-HTTP registries go in `FERRY_INSECURE_REGISTRIES`, comma separated,
when ferry starts. Anything else is HTTPS, as before.

It is not on 5000 because macOS's AirPlay Receiver holds `*:5000`, and answers a
registry client there with `403` from a server calling itself AirTunes.

Before this, a plain-HTTP registry could not be pulled from at all: pulling
from one on a pod's address fails after about a minute with `-9836: bad
protocol version`, TLS meeting HTTP, and so did `localtest.me:5001` -- a public
name for 127.0.0.1 -- until it was named in `FERRY_INSECURE_REGISTRIES`, when it
pulled. From localhost a pull takes 13 to 60 ms, and a fresh image pushed with
`crane`, pulled and run took 3 s end to end.

## Found on the way

- **A hostPort in front of a different containerPort reached the pod's own
  port.** With `hostPort: 5001, containerPort: 5000`, a request to
  `localhost:5001` arrived in the pod on 5001 -- where registry:3's debug server
  answered 404 -- instead of being rewritten to 5000. The registry listens on
  5001 inside the pod as well, which sidesteps it; the cause is not found.
- **cAdvisor on a Mac has no container series.** `/metrics/cadvisor` serves
  machine facts only, so the prometheus addon scrapes `/metrics/resource`,
  which has `container_memory_working_set_bytes` per container.
- **`kubectl get -f` of one object is not a List**, so the first rollout wait,
  reading `.items`, waited for nothing on a one-Deployment manifest and said
  "ready in 0s". A deliberately broken addon caught it.
- **`ferry down` stopped every profile's ferry-proxy**, with a `pkill` that
  matched every checkout's; this cluster's LoadBalancers and hostPorts vanished
  twice while other sessions shut down. It now matches this profile's
  kubeconfig.
