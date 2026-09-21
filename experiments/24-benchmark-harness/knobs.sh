#!/usr/bin/env bash
# The kubelet knobs that bound how many pods can start at once, side by side.
set -uo pipefail
cd "$(dirname "$0")"

KEYS='kubeAPIQPS|kubeAPIBurst|maxPods|serializeImagePulls|maxParallelImagePulls|registryPullQPS|registryBurst|eventRecordQPS|eventBurst|cgroupDriver|cgroupsPerQPod|cgroupsPerQOSPod|cgroupsPerQOS|runtimeRequestTimeout|nodeStatusUpdateFrequency|syncFrequency'

probe() { # label kubeconfig node
  local label="$1" kc="$2" node="$3"
  export KUBECONFIG="$kc"
  kubectl delete pod knobs --ignore-not-found >/dev/null 2>&1
  sleep 2
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: knobs}
spec:
  nodeName: $node
  terminationGracePeriodSeconds: 0
  hostPID: true
  containers:
  - name: c
    image: alpine:3.20
    command: ["sleep","3600"]
    securityContext: {privileged: true, runAsUser: 0}
    volumeMounts: [{name: h, mountPath: /host}]
  volumes:
  - name: h
    hostPath: {path: /}
YAML
  kubectl wait --for=condition=Ready pod/knobs --timeout=180s >/dev/null 2>&1 || {
    echo "== $label: probe did not start"; return; }

  echo "== $label ($node)"
  echo "  argv:"
  kubectl exec knobs -- sh -c \
    'for p in /proc/[0-9]*; do
       c=$(tr "\0" " " < $p/cmdline 2>/dev/null)
       case "$c" in */kubelet*|kubelet*) echo "$c"; break;; esac
     done' 2>/dev/null | tr ' ' '\n' | grep -E '^--' | sed 's/^/    /'
  echo "  config.yaml:"
  kubectl exec knobs -- sh -c \
    "grep -iE '$KEYS' /host/var/lib/kubelet/config.yaml 2>/dev/null" | sed 's/^/    /'
  kubectl delete pod knobs --ignore-not-found --wait=false >/dev/null 2>&1
  echo
}

probe ferry "$(./ferry kubeconfig)" perf-0
kk="$HOME/.kube/config-perfk"
probe kind "$kk" "$(KUBECONFIG=$kk kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
