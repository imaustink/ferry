# node-app

A production-shaped Node/Express service, built into a Linux image with
`ferry image build` instead of `docker build` / `docker buildx build`, and
deployed the way a real service is: a multi-replica `Deployment`, not a bare
`Pod`, with health probes, resource limits, a non-root/read-only-rootfs
security context, a `NetworkPolicy`, and a `PodDisruptionBudget`.

This answers a specific question: a build pipeline that reaches for Docker
only to build a Node image can drop Docker there, run `ferry image build`
instead, and keep everything downstream (`Deployment`, probes, rollout)
exactly as a Kubernetes-native pipeline already expects. See
[docs/RUNTIMES.md#building-an-image-without-docker](../docs/RUNTIMES.md#building-an-image-without-docker)
for how the builder works, and
[experiments/25-build-without-docker](../experiments/25-build-without-docker/FINDINGS.md)
for the benchmarks against Docker Desktop and colima.

```
node-app/
  package.json, package-lock.json  express + helmet; npm ci needs the lockfile
  src/index.js           /healthz (liveness), /readyz (readiness), graceful
                          SIGTERM shutdown, helmet's security headers,
                          structured JSON logs
  Dockerfile             multi-stage, non-root, tini as pid 1, HEALTHCHECK
  .dockerignore
  build.sh               `ferry image build -t node-app:1 .`
  manifests/
    deployment.yaml       3 replicas, rolling update, probes, resource
                           limits, a locked-down securityContext
    service.yaml           ClusterIP
    networkpolicy.yaml     same-namespace-only ingress on :8080
    poddisruptionbudget.yaml  minAvailable: 2
    kustomization.yaml
  run.sh                 apply, wait for the rollout, prove the Service
                          answers from inside the cluster, print logs
```

## No CI yet, on purpose

There is no `.github/workflows/` entry for this. `ferry` itself needs a
self-hosted Apple-silicon runner to build or run anything here at all — a
pod is a `Virtualization.framework` VM, and GitHub's hosted `macos-*`
runners disable nested virtualization — and that runner is not set up yet.
Until it is, `./build.sh` and `./run.sh` below are run by hand on the same
Mac releases are cut from, the same way
[the top-level README's release process](../README.md#cutting-a-release)
already works. Wiring this into CI later is only pointing a workflow at
these same two scripts once a runner exists.

## Prerequisites

`buildctl` on the Mac (`brew install buildkit`) and a running cluster
(`ferry up`). Docker Desktop does not need to be installed, let alone
running.

## Build and run

```sh
cd node-app
./build.sh    # ferry image build -t node-app:1 .
./run.sh      # kubectl apply -k manifests/, waits for the rollout, verifies it
```

`run.sh` does not curl a ClusterIP from the Mac — Services on ferry are
routed **inside each pod's own kernel** by kube-proxy's real ruleset
(`docs/SERVICES.md`); the Mac's kernel has no netfilter to do that with, so a
ClusterIP is only reachable from inside the cluster. `run.sh` proves the
Service the way every other pod actually reaches it: `kubectl exec` into one
of the running pods and requests `http://node-app/` by its cluster-DNS name.
Expect:

```
==> node-app Service, reached by DNS name from inside pod node-app-7df79764b8-7x47l
hello from node-app, built with ferry image build

==> readiness of that same pod, direct
200
```

**Verified end to end** against this Mac's ferry v0.11.0 cluster:

- cold `./build.sh` runs the multi-stage build (`npm ci` in the `deps`
  stage, a non-root `USER node`, `tini` as pid 1) inside the builder pod
  and produces `node-app:1`;
- `./run.sh` rolls out 3 replicas, all pass their `startupProbe` and
  `readinessProbe`, the `Service` answers by DNS name from inside the
  cluster, and `/readyz` on a live pod returns `200`;
- a probe pod in a **different** namespace, added by hand against the same
  manifests, timed out reaching `node-app` — the `NetworkPolicy` is
  enforced, not just present;
- `kubectl delete -k manifests/` and `ferry image build --stop` both leave
  the cluster clean.

## What "production grade" covers here, and what it does not

- **Covers:** the build (no Docker), the rollout (`Deployment`, probes,
  `PodDisruptionBudget`), and the security posture of the pod itself
  (non-root, read-only rootfs, dropped capabilities, `NetworkPolicy`).
- **Does not cover: automation.** See "No CI yet, on purpose" above —
  `build.sh` and `run.sh` are run by hand today.
- **Does not cover: shipping the image to a registry.** `ferry image build`
  loads straight into the image store pods on *this cluster* are served
  from (and, via `ferry-registry`, every other node or Mac already joined
  to it — see `docs/RUNTIMES.md`). It has no `push` subcommand today. If a
  deployment target is a *different* cluster than the one that built the
  image, that image still needs to reach it some other way (a registry
  push from the builder's output, or another node joining this cluster
  with `ferry token create`). Treat this as the boundary of what's proven
  here, not an oversight.

## Cleaning up

```sh
kubectl --kubeconfig ~/.ferry/admin.conf delete -k manifests/ --ignore-not-found
ferry image build --stop   # stop the builder pod; the layer cache goes with it
```
