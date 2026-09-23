#!/usr/bin/env bash
# The measurements in FINDINGS.md, against a running cluster from this checkout.
#
#   ./run.sh images    a loaded image on another node, and through another "Mac"
#   ./run.sh volumes   chown, movement and throughput of a ferry-local-block claim
#   ./run.sh nfs       the unprivileged NFS server spike (needs nfsspike running)
#
# images wants a cluster with no added nodes; volumes and nfs want machines on
# (`ferry machines enable`) and a kernel with usb-storage (`ferry kernel`).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
ferry="$repo/ferry"
: "${KUBECONFIG:?export the KUBECONFIG ferry up printed}"
# The peer port is 5051 plus the profile's shift; `ferry profile` shows the
# shift through its other ports. A worktree cluster has to say it.
PEER_PORT="${FERRY_REGISTRY_PEER_PORT:-5051}"
ts() { python3 -c 'import time;print("%.3f"%time.time())'; }
pulled() { kubectl get events --field-selector "involvedObject.name=$1" | grep -o 'pulled image.*' | head -1; }

images() {
  local dir; dir="$(mktemp -d)"
  printf 'FROM public.ecr.aws/docker/library/busybox:1.36\nRUN echo cluster-wide-33 > /marker && dd if=/dev/urandom of=/blob bs=1M count=64\nCMD ["sh","-c","cat /marker; sleep 3600"]\n' > "$dir/Dockerfile"
  docker build --platform linux/arm64 -q -t ferry33/hello:dev "$dir" >/dev/null
  "$ferry" node add n1 >/dev/null
  "$ferry" image load ferry33/hello:dev
  # Added after the load, so it has only the registry to get it from.
  "$ferry" node add n2 >/dev/null
  kubectl run hello-n1 --image=ferry33/hello:dev --image-pull-policy=Never --overrides='{"spec":{"nodeName":"n1"}}'
  kubectl run hello-n2 --image=ferry33/hello:dev --image-pull-policy=IfNotPresent --overrides='{"spec":{"nodeName":"n2"}}'
  kubectl wait --for=condition=Ready pod/hello-n1 pod/hello-n2 --timeout=120s
  kubectl logs hello-n1; kubectl logs hello-n2; pulled hello-n2

  # A second Mac, as far as one Mac can play one: a registry with an empty
  # store whose only source is this Mac's peer port, and a node that asks it.
  local store; store="$(mktemp -d)"
  local home; home="$(dirname "$KUBECONFIG")"
  "$repo/bin/ferry-registry" serve --store "$store" --listen 127.0.0.1:27060 \
    --kubeconfig "$home/kubelet.conf" --peers "https://$(ipconfig getifaddr en0):$PEER_PORT" &
  local peer=$!
  sleep 1
  FERRY_MACHINE_REGISTRY_PORT=27060 "$ferry" node add n3 >/dev/null
  kubectl run hello-n3 --image=ferry33/hello:dev --image-pull-policy=IfNotPresent --overrides='{"spec":{"nodeName":"n3"}}'
  kubectl wait --for=condition=Ready pod/hello-n3 --timeout=120s
  kubectl logs hello-n3; pulled hello-n3
  kill "$peer"
}

volumes() {
  kubectl apply -f "$here/block-claim.yaml"
  kubectl wait --for=condition=Ready pod/owner --timeout=240s
  kubectl logs owner -c chown; kubectl logs owner -c app
  kubectl delete pod owner --grace-period=1
  kubectl apply -f "$here/perf.yaml"
  kubectl wait --for=condition=Ready pod/perf --timeout=240s
  until [ "$(kubectl logs perf 2>/dev/null | grep -c round)" -ge 9 ]; do sleep 5; done
  kubectl logs perf
  kubectl delete pod perf --grace-period=1
}

nfs() {
  kubectl apply -f "$here/nfs-spike.yaml"
  kubectl wait --for=condition=Ready pod/nfs --timeout=240s
  until [ "$(kubectl logs nfs 2>/dev/null | grep -c 'round\|failed')" -ge 6 ]; do sleep 5; done
  kubectl logs nfs
  kubectl delete pod nfs --grace-period=1
}

"${1:-images}"
