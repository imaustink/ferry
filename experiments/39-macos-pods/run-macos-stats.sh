#!/usr/bin/env bash
# Container CPU and memory from a macOS pod, through the kubelet's summary API --
# what `kubectl top` and metrics-server read. A pod burns CPU and holds memory;
# its container's counters should be non-zero and rise. Boots mac-0 if not up.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
state=$("$here/../../ferry" profile | awk '$1 == "state" {print $2}')
export KUBECONFIG="$state/admin.conf"
k() { kubectl "$@"; }
img=example.com/podsrv-darwin:3

k apply -f "$here/macos-machine.yaml" >/dev/null
for _ in $(seq 180); do k get node mac-0 >/dev/null 2>&1 && break; sleep 1; done
k wait --for=condition=Ready node/mac-0 --timeout=180s >/dev/null || { echo "mac-0 not Ready"; exit 1; }

k delete pod busy --ignore-not-found --wait=true >/dev/null 2>&1
k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: busy, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-macos-shared
  nodeSelector: {kubernetes.io/hostname: mac-0}
  containers:
    - name: busy
      image: $img
      # Hold ~40 MB resident in a shell variable and keep a core busy, so CPU
      # rises and memory is real RSS, not a file.
      command: [/bin/sh, -c, 'hold=\$(head -c 40000000 /dev/zero | tr "\0" a); while :; do :; done']
      resources: {requests: {cpu: 100m, memory: 64Mi}}
EOF
k wait --for=condition=Ready pod/busy --timeout=120s >/dev/null || { echo "busy not Ready"; exit 1; }

# The summary API, twice, ten seconds apart: CPU is a cumulative counter, so it
# should climb; memory should be non-zero throughout.
summary() { k get --raw "/api/v1/nodes/mac-0/proxy/stats/summary"; }
read_one() {
    summary | python3 -c '
import json, sys
s = json.load(sys.stdin)
for pod in s.get("pods", []):
    if pod["podRef"]["name"] != "busy":
        continue
    for c in pod.get("containers", []):
        cpu = (c.get("cpu") or {}).get("usageCoreNanoSeconds")
        mem = (c.get("memory") or {}).get("workingSetBytes")
        print(c["name"], "cpu_ns=" + str(cpu), "mem_bytes=" + str(mem))
'
}
echo "=== container stats for pod busy, from the summary API"
first=$(read_one); echo "    t0: $first"
sleep 10
second=$(read_one); echo "    t1: $second"

c0=$(echo "$first"  | sed -n 's/.*cpu_ns=\([0-9]*\).*/\1/p')
c1=$(echo "$second" | sed -n 's/.*cpu_ns=\([0-9]*\).*/\1/p')
m1=$(echo "$second" | sed -n 's/.*mem_bytes=\([0-9]*\).*/\1/p')
verdict="?"
if [ -n "${c0:-}" ] && [ -n "${c1:-}" ] && [ -n "${m1:-}" ] && [ "$c1" -gt "$c0" ] && [ "$m1" -gt 0 ]; then
    verdict="ok: CPU rose $(( (c1 - c0) / 1000000 )) ms over 10 s, memory $(( m1 / 1048576 )) MiB"
else
    verdict="FAILED (c0=$c0 c1=$c1 mem=$m1)"
fi
echo "    verdict: $verdict"

# metrics-server, if this cluster has one.
if k top pod busy --no-headers >/dev/null 2>&1; then
    echo "=== kubectl top pod busy"
    k top pod busy 2>&1 | sed 's/^/    /'
fi
k delete pod busy --wait=false >/dev/null 2>&1
