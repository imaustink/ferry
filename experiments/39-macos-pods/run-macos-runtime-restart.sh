#!/usr/bin/env bash
# The runtime restarts; the pods do not notice.
#
#   1. crash   ferry-darwin is SIGKILLed; launchd starts it again. Every pod
#              keeps its container (same id, no restart), its address, and
#              serving; a counter's log has no gap; exec and a PVC still work.
#   2. pause   ferry-darwin is stopped for 20 s while a Job's pod exits 3. The
#              restarted runtime reports exit 3 -- the reaper kept it -- not a
#              made-up failure, and the counter's lines from the gap arrive.
#   3. stop    deleting an adopted pod stops it promptly.
#
# Boots mac-0 if it is not up.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
state=$("$here/../../ferry" profile | awk '$1 == "state" {print $2}')
export KUBECONFIG="$state/admin.conf"
k() { kubectl "$@"; }
img=example.com/podsrv-darwin:3
cfg="$state/machined/mac-0.macvm.config"
rtlog="$state/machined/mac-0.macvm.logs/runtime.log"

k apply -f "$here/macos-machine.yaml" >/dev/null
for _ in $(seq 180); do k get node mac-0 >/dev/null 2>&1 && break; sleep 1; done
k wait --for=condition=Ready node/mac-0 --timeout=180s >/dev/null || { echo "mac-0 not Ready"; exit 1; }

k delete pod web counter pvpod finisher shell --ignore-not-found --wait=true >/dev/null 2>&1
k delete pvc rr-data --ignore-not-found --wait=true >/dev/null 2>&1
k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: web, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-macos-shared
  nodeSelector: {kubernetes.io/hostname: mac-0}
  containers: [{name: web, image: $img, args: [serve, web]}]
---
apiVersion: v1
kind: Pod
metadata: {name: counter, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-macos-shared
  nodeSelector: {kubernetes.io/hostname: mac-0}
  containers:
    - name: c
      image: $img
      command: [/bin/sh, -c, 'i=0; while :; do i=\$((i+1)); echo "n=\$i"; sleep 1; done']
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: rr-data, labels: {experiment: "39"}}
spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 1Gi}}}
---
apiVersion: v1
kind: Pod
metadata: {name: pvpod, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-macos-shared
  nodeSelector: {kubernetes.io/hostname: mac-0}
  volumes: [{name: d, persistentVolumeClaim: {claimName: rr-data}}]
  containers:
    - name: c
      image: $img
      command: [/bin/sh, -c, 'echo before > /data/f; sleep 3600']
      volumeMounts: [{name: d, mountPath: /data}]
---
apiVersion: v1
kind: Pod
metadata: {name: shell, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-macos-shared
  nodeSelector: {kubernetes.io/hostname: mac-0}
  containers:
    - name: c
      image: $img
      # A terminal container: its pty is the reaper's, not the runtime's, so it
      # has to survive a restart like the rest.
      command: [/bin/sh, -c, 'sleep 3600']
      tty: true
      stdin: true
EOF
# 300 s: ferry-storage has been seen to take ~2.5 min to provision a claim for a
# node that has just registered.
k wait --for=condition=Ready pod/web pod/counter pod/pvpod pod/shell --timeout=300s >/dev/null || { echo "pods not Ready"; exit 1; }
sleep 3

snap() { # pod -> "containerID restarts ip"
    k get pod "$1" -o jsonpath='{.status.containerStatuses[0].containerID} {.status.containerStatuses[0].restartCount} {.status.podIP}'
}
serves() { k exec web -- /bin/podsrv get "$(k get pod web -o jsonpath='{.status.podIP}')" 8080 2>&1 | head -1; }
restored_count() { n=$(grep -ac "state: restored" "$rtlog" 2>/dev/null); echo "${n:-0}"; }
wait_restored() { # count-before
    for _ in $(seq 60); do [ "$(restored_count)" -gt "$1" ] && return 0; sleep 1; done
    return 1
}
request() { # crash|pause: write the next restart-runtime-N (see ferry-macos-init)
    n=1; while [ -e "$cfg/restart-runtime-$n" ]; do n=$((n + 1)); done
    echo "$1" > "$cfg/restart-runtime-$n"
}
same() { # name before after
    if [ "$2" = "$3" ]; then echo "    $1: same container, no restart, same address ($3)"; return 0; fi
    echo "    $1: CHANGED  before=[$2] after=[$3]"; return 1
}

echo "=== 1. crash: SIGKILL ferry-darwin"
b_web=$(snap web); b_cnt=$(snap counter); b_pv=$(snap pvpod); b_sh=$(snap shell)
echo "    web answers: $(serves)"
n0=$(restored_count)
request crash
if wait_restored "$n0"; then
    grep -a "state: restored" "$rtlog" | tail -1 | sed 's/^/    runtime: /'
else
    echo "    runtime did not restart"; tail -5 "$rtlog" | sed 's/^/    /'
fi
sleep 3
ok=0
same web "$b_web" "$(snap web)" && ok=$((ok+1))
same counter "$b_cnt" "$(snap counter)" && ok=$((ok+1))
same pvpod "$b_pv" "$(snap pvpod)" && ok=$((ok+1))
same shell "$b_sh" "$(snap shell)" && ok=$((ok+1))  # the terminal container
echo "    web answers: $(serves)"
serves | grep -q . && ok=$((ok+1))
pvw=$(k exec pvpod -- /bin/sh -c 'echo after >> /data/f; cat /data/f' 2>&1 | tr '\n' ' ')
echo "    exec + PVC after the restart: $pvw"
[ "$pvw" = "before after " ] && ok=$((ok+1))
echo "    exec into the terminal pod: $(k exec shell -- /bin/echo alive 2>&1 | tr -d '\r')"
echo "    crash verdict: $ok of 6"

echo "=== 2. pause: runtime down 20 s while a Job's pod exits 3"
k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: finisher, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-macos-shared
  nodeSelector: {kubernetes.io/hostname: mac-0}
  restartPolicy: Never
  containers: [{name: c, image: $img, command: [/bin/sh, -c, 'sleep 8; echo finishing; exit 3']}]
EOF
k wait --for=condition=Ready pod/finisher --timeout=60s >/dev/null
n0=$(restored_count)
request pause
wait_restored "$n0" || echo "    runtime did not come back"
restored=$(grep -a "state: restored" "$rtlog" | tail -1)
echo "    runtime: $restored"
grep -a "ferry-macos-init: restart-runtime" "$state/machined/mac-0.macvm.logs/init.log" | tail -2 | sed 's/^/    init: /'
for _ in $(seq 30); do
    case "$(k get pod finisher -o jsonpath='{.status.phase}')" in Succeeded|Failed) break ;; esac
    sleep 1
done
code=$(k get pod finisher -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}')
echo "    finisher: $(k get pod finisher -o jsonpath='{.status.phase}'), exit $code, log: $(k logs finisher 2>&1 | tr '\n' ' ')"
# Only a pass if the runtime says the container ended while it was down --
# otherwise the Job just exited with the runtime up, and nothing was tested.
if [ "$code" = 3 ] && echo "$restored" | grep -qE '[1-9][0-9]* ended while the runtime was down'; then
    echo "    exit verdict: ok (exit 3 kept while the runtime was down)"
else
    echo "    exit verdict: FAILED"
fi
sleep 2
same counter "$b_cnt" "$(snap counter)" >/dev/null && echo "    counter: still the same container"
# Every n from the first to the last, once each: nothing lost, nothing twice.
gaps=$(k logs counter | sed -n 's/^n=//p' | awk 'NR==1{p=$1; next} {if ($1 != p+1) g++; p=$1} END {print g+0 " gaps, " NR " lines"}')
echo "    counter log across both restarts: $gaps"
case "$gaps" in "0 gaps,"*) echo "    log verdict: ok" ;; *) echo "    log verdict: FAILED" ;; esac

echo "=== 3. stop: delete an adopted pod"
t0=$(date +%s)
k delete pod web --wait=true --timeout=60s >/dev/null 2>&1
echo "    web deleted in $(( $(date +%s) - t0 )) s"
[ $(( $(date +%s) - t0 )) -lt 40 ] && echo "    stop verdict: ok" || echo "    stop verdict: FAILED"

k delete pod counter pvpod finisher shell --wait=false >/dev/null 2>&1
k delete pvc rr-data --wait=false >/dev/null 2>&1
