#!/usr/bin/env bash
# CPU limits on a macOS pod. There is no CFS quota, so ferry-darwin duty-cycles
# the container with SIGSTOP/SIGCONT. Two busy loops, one capped at 200m and one
# uncapped: measured over a few seconds through the summary API, the capped one
# should sit near 0.2 cores and the uncapped one near a whole core. Boots mac-0.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
state=$("$here/../../ferry" profile | awk '$1 == "state" {print $2}')
export KUBECONFIG="$state/admin.conf"
k() { kubectl "$@"; }
img=example.com/podsrv-darwin:3

k apply -f "$here/macos-machine.yaml" >/dev/null
for _ in $(seq 180); do k get node mac-0 >/dev/null 2>&1 && break; sleep 1; done
k wait --for=condition=Ready node/mac-0 --timeout=180s >/dev/null || { echo "mac-0 not Ready"; exit 1; }

k delete pod capped uncapped --ignore-not-found --wait=true >/dev/null 2>&1
k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: capped, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-macos-shared
  nodeSelector: {kubernetes.io/hostname: mac-0}
  containers:
    - name: c
      image: $img
      command: [/bin/sh, -c, 'while :; do :; done']
      resources: {limits: {cpu: 200m}}
---
apiVersion: v1
kind: Pod
metadata: {name: uncapped, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-macos-shared
  nodeSelector: {kubernetes.io/hostname: mac-0}
  containers:
    - name: c
      image: $img
      command: [/bin/sh, -c, 'while :; do :; done']
EOF
k wait --for=condition=Ready pod/capped pod/uncapped --timeout=120s >/dev/null || { echo "not Ready"; exit 1; }

sample() { k get --raw "/api/v1/nodes/mac-0/proxy/stats/summary" \
    | python3 -c 'import json,sys
s=json.load(sys.stdin)
for p in s.get("pods",[]):
    if p["podRef"]["name"]==sys.argv[1]:
        for c in p.get("containers",[]):
            v=(c.get("cpu") or {}).get("usageCoreNanoSeconds")
            if v is not None: print(v)' "$1"; }

win=6
a_cap=$(sample capped); a_unc=$(sample uncapped); t0=$(date +%s.%N)
sleep $win
b_cap=$(sample capped); b_unc=$(sample uncapped); t1=$(date +%s.%N)
report() { # name a b
    python3 -c 'import sys
a,b=int(sys.argv[2]),int(sys.argv[3]); el=float(sys.argv[4])
cores=(b-a)/1e9/el
print("%s: %.2f cores over %.1fs" % (sys.argv[1], cores, el))' "$1" "$2" "$3" "$(python3 -c "print($t1-$t0)")"; }
echo "=== CPU used while both busy-loop"
cap_line=$(report capped "$a_cap" "$b_cap"); echo "    $cap_line"
unc_line=$(report uncapped "$a_unc" "$b_unc"); echo "    $unc_line"
capv=$(echo "$cap_line" | sed -n 's/.*: \([0-9.]*\) cores.*/\1/p')
uncv=$(echo "$unc_line" | sed -n 's/.*: \([0-9.]*\) cores.*/\1/p')
ok=$(python3 -c "print('ok' if $capv < 0.4 and $uncv > $capv*1.8 else 'FAILED')")
echo "    verdict: $ok (capped near 0.2, uncapped much higher)"
k delete pod capped uncapped --wait=false >/dev/null 2>&1
