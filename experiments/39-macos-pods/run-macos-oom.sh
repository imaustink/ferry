#!/usr/bin/env bash
# Memory limits on a macOS pod. There is no cgroup, so ferry-darwin watches the
# container's process group and kills it when it passes the limit.
#
#   hog     limit 64Mi, tries to hold ~256 MB   -> OOMKilled, exit 137
#   within  limit 256Mi, ordinary footprint     -> stays Running
#
# The watcher counts phys_footprint and polls, so it catches a transient spike
# a hard cgroup barrier would also reject -- bash's `$(...)` buffering a big
# string briefly holds many times the final size. So `within` does not allocate
# a large buffer; it is the negative case, a normal pod that must not be killed.
#
# Boots mac-0 if it is not up.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
state=$("$here/../../ferry" profile | awk '$1 == "state" {print $2}')
export KUBECONFIG="$state/admin.conf"
k() { kubectl "$@"; }
img=example.com/podsrv-darwin:3

k apply -f "$here/macos-machine.yaml" >/dev/null
for _ in $(seq 180); do k get node mac-0 >/dev/null 2>&1 && break; sleep 1; done
k wait --for=condition=Ready node/mac-0 --timeout=180s >/dev/null || { echo "mac-0 not Ready"; exit 1; }

k delete pod hog within --ignore-not-found --wait=true >/dev/null 2>&1
k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: hog, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-macos-shared
  nodeSelector: {kubernetes.io/hostname: mac-0}
  restartPolicy: Never
  containers:
    - name: hog
      image: $img
      command: [/bin/sh, -c, 'hold=\$(head -c 268435456 /dev/zero | tr "\0" a); echo "survived with \${#hold} bytes"; sleep 30']
      resources: {limits: {memory: 64Mi}}
---
apiVersion: v1
kind: Pod
metadata: {name: within, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-macos-shared
  nodeSelector: {kubernetes.io/hostname: mac-0}
  restartPolicy: Never
  containers:
    - name: within
      image: $img
      command: [/bin/sh, -c, 'echo "within is up as uid \$(id -u)"; sleep 60']
      resources: {limits: {memory: 256Mi}}
EOF

echo "=== hog: limit 64Mi, tries to hold 256 MB"
for _ in $(seq 120); do
    case "$(k get pod hog -o jsonpath='{.status.phase}')" in Succeeded|Failed) break ;; esac
    sleep 1
done
reason=$(k get pod hog -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}')
code=$(k get pod hog -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}')
echo "    phase=$(k get pod hog -o jsonpath='{.status.phase}') reason=$reason exitCode=$code"
echo "    logs: $(k logs hog 2>&1 | tr '\n' ' ')"
[ "$reason" = OOMKilled ] && [ "$code" = 137 ] && echo "    verdict: ok (killed at its limit)" || echo "    verdict: FAILED"

echo "=== within: limit 256Mi, an ordinary pod"
k wait --for=condition=Ready pod/within --timeout=60s >/dev/null 2>&1
sleep 3
echo "    phase=$(k get pod within -o jsonpath='{.status.phase}') restarts=$(k get pod within -o jsonpath='{.status.containerStatuses[0].restartCount}')"
echo "    logs: $(k logs within 2>&1 | tr '\n' ' ')"
[ "$(k get pod within -o jsonpath='{.status.phase}')" = Running ] && echo "    verdict: ok (runs within its limit)" || echo "    verdict: FAILED"

k delete pod hog within --wait=false >/dev/null 2>&1
grep -a "OOMKilled" "$state/machined/mac-0.macvm.logs/runtime.log" 2>/dev/null | tail -1 | sed 's/^/    runtime: /'
