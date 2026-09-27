#!/usr/bin/env bash
# Container restart: when a container exits, the kubelet restarts it in the same
# sandbox (RemoveContainer + CreateContainer + StartContainer), and a liveness
# probe that fails drives the same path. The pod keeps its IP; restartCount
# climbs. Boots mac-0 if not up.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
state=$("$here/../../ferry" profile | awk '$1 == "state" {print $2}')
export KUBECONFIG="$state/admin.conf"
k() { kubectl "$@"; }
img=example.com/podsrv-darwin:3

k apply -f "$here/macos-machine.yaml" >/dev/null
for _ in $(seq 180); do k get node mac-0 >/dev/null 2>&1 && break; sleep 1; done
k wait --for=condition=Ready node/mac-0 --timeout=180s >/dev/null || { echo "mac-0 not Ready"; exit 1; }

k delete pod flaky live --ignore-not-found --wait=true >/dev/null 2>&1
k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: flaky, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-macos-shared
  nodeSelector: {kubernetes.io/hostname: mac-0}
  restartPolicy: Always
  containers:
    - name: c
      image: $img
      # Exit non-zero after a few seconds, over and over.
      command: [/bin/sh, -c, 'echo "start \$(date +%s)"; sleep 4; echo crashing; exit 1']
---
apiVersion: v1
kind: Pod
metadata: {name: live, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-macos-shared
  nodeSelector: {kubernetes.io/hostname: mac-0}
  restartPolicy: Always
  containers:
    - name: c
      image: $img
      # Healthy for ~8 s, then the marker goes and the liveness probe fails.
      command: [/bin/sh, -c, 'touch /tmp/ok; (sleep 8; rm -f /tmp/ok); sleep 3600']
      livenessProbe:
        exec: {command: [/bin/sh, -c, 'test -f /tmp/ok']}
        initialDelaySeconds: 2
        periodSeconds: 2
        failureThreshold: 1
EOF

echo "=== flaky: restartPolicy Always, crashes every ~4 s"
ip0=$(for _ in $(seq 60); do ip=$(k get pod flaky -o jsonpath='{.status.podIP}'); [ -n "$ip" ] && { echo "$ip"; break; }; sleep 1; done)
for _ in $(seq 60); do [ "$(k get pod flaky -o jsonpath='{.status.containerStatuses[0].restartCount}')" -ge 2 ] 2>/dev/null && break; sleep 2; done
rc=$(k get pod flaky -o jsonpath='{.status.containerStatuses[0].restartCount}')
ip1=$(k get pod flaky -o jsonpath='{.status.podIP}')
echo "    restartCount=$rc, IP $ip0 -> $ip1 (want: climbing, IP unchanged)"
[ "${rc:-0}" -ge 2 ] && [ -n "$ip0" ] && [ "$ip0" = "$ip1" ] && echo "    verdict: ok" || echo "    verdict: FAILED"

echo "=== live: a failing liveness probe restarts the container"
for _ in $(seq 90); do [ "$(k get pod live -o jsonpath='{.status.containerStatuses[0].restartCount}')" -ge 1 ] 2>/dev/null && break; sleep 2; done
rc=$(k get pod live -o jsonpath='{.status.containerStatuses[0].restartCount}')
echo "    restartCount=$rc, phase=$(k get pod live -o jsonpath='{.status.phase}')"
k get events --field-selector involvedObject.name=live -o custom-columns=REASON:.reason,MSG:.message 2>&1 | grep -iE "unhealthy|killing|liveness" | tail -2 | sed 's/^/    /'
[ "${rc:-0}" -ge 1 ] && echo "    verdict: ok" || echo "    verdict: FAILED"

k delete pod flaky live --wait=false >/dev/null 2>&1
