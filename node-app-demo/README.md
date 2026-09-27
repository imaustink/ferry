# Node app demo

A minimal Node/Express app, built into a Linux pod image with `ferry image
build` instead of `docker build`. No Docker daemon, no Docker Desktop, no
`docker buildx` -- just `buildctl` talking to a buildkit pod ferry starts on
the cluster. See
[docs/RUNTIMES.md#building-an-image-without-docker](../docs/RUNTIMES.md#building-an-image-without-docker)
for how that works, and
[experiments/25-build-without-docker](../experiments/25-build-without-docker/FINDINGS.md)
for the benchmarks against Docker Desktop and colima.

```
node-app-demo/
  package.json        one real dependency (express), not a formality
  src/index.js        listens on :8080, replies on GET /
  Dockerfile           FROM node:22-alpine -- an ordinary Linux app image
  build.sh            `ferry image build -t node-app-demo:1 .`
  manifests/pod.yaml  the pod itself
  run.sh              apply, wait, curl the pod, print its logs
```

## Prerequisite

`buildctl` on the Mac (`brew install buildkit`), and a running cluster
(`ferry up`). That's it -- Docker Desktop does not need to be installed.

## Build and run

```sh
cd node-app-demo
./build.sh    # ferry image build -t node-app-demo:1 .
./run.sh      # applies manifests/pod.yaml, waits for Running, curls it
```

`run.sh` curls the pod directly on its own IP -- the Mac is already on the
pod subnet, so nothing needs a port-forward or a published port
([docs/POD-NETWORK.md](../docs/POD-NETWORK.md)). Expect:

```
==> curl http://10.244.0.x:8080/
hello from node-app-demo, built with ferry image build
```

**Verified end to end** against this Mac's ferry v0.11.0 cluster: cold
`./build.sh` runs `npm install` inside the builder pod and produces
`node-app-demo:1`; `./run.sh` schedules the pod, gets a 200 from `curl`, and
prints `listening on :8080` from `kubectl logs`.

## Cleaning up

```sh
kubectl --kubeconfig ~/.ferry/admin.conf delete pod node-app-demo --ignore-not-found
ferry image build --stop   # stop the builder pod; the layer cache goes with it
```
