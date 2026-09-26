#!/usr/bin/env bash
# Why a Linux machine's pod cannot reach a macOS pod: tcpdump on the macOS
# node's two cards while the Linux pod connects, and the Linux machine's route
# to the macOS node's pod slice.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
state=$("$here/../../ferry" profile | awk '$1 == "state" {print $2}')
export KUBECONFIG="$state/admin.conf"
k() { kubectl "$@"; }
img=example.com/podsrv-darwin:3

k delete pod trace --ignore-not-found >/dev/null 2>&1
wip=$(k get node worker-0 -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
wcidr=$(k get node worker-0 -o jsonpath='{.spec.podCIDR}'); wgw="${wcidr%.*}.$(( ${wcidr##*.} + 1 ))"; wgw="${wgw%/*}"
echo "worker-0: $wip, pod switch address $wgw"
k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: t-mac, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-macos-shared
  containers: [{name: web, image: $img, args: [serve, mac-web]}]
---
apiVersion: v1
kind: Pod
metadata: {name: t-lm, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-shared
  containers: [{name: c, image: busybox:1.36, command: [sleep, "3600"]}]
---
apiVersion: v1
kind: Pod
metadata: {name: trace, labels: {experiment: "39"}, annotations: {ferry.dev/debug-host: "true"}}
spec:
  runtimeClassName: ferry-macos-shared
  restartPolicy: Never
  containers:
    - name: t
      image: $img
      command: [/bin/sh, -c, 'echo "check_interface: \$(sysctl -n net.inet.ip.check_interface)"; pfctl -a ferry -s rules 2>/dev/null | head -4; (/usr/sbin/tcpdump -l -n -i any -c 20 "tcp port 8080" 2>&1 &); sleep 9; echo "scopedroute: \$(sysctl -n net.inet.ip.scopedroute 2>&1)"; P=\$(ifconfig -l | tr " " "\n" | while read i; do ifconfig \$i | grep -q "inet 10.190" && echo \$i; done); M=\$(route -n get default | awk "/interface/{print \\\$2}"); echo "--- in \$P scope: $wip via $wgw"; route -n add -ifscope \$P -host $wip $wgw 2>&1; sleep 9; route -n delete -ifscope \$P -host $wip 2>&1; echo "--- route removed"; sleep 2']
EOF
k wait --for=condition=Ready pod/t-mac pod/t-lm pod/trace --timeout=180s >/dev/null
mac=$(k get pod t-mac -o jsonpath='{.status.podIP}')
sleep 3
echo "=== t-lm -> $mac:8080"
k exec t-lm -- sh -c "nc -w 5 $mac 8080 </dev/null; echo nc exit \$?" 2>&1 | sed 's/^/    /'
echo "=== the Linux machine's route to it"
k exec t-lm -- sh -c "ip route get $mac" 2>&1 | sed 's/^/    /'
sleep 6
echo "=== t-lm -> $mac:8080, with the scoped route"
k exec t-lm -- sh -c "nc -w 5 $mac 8080 </dev/null; echo nc exit \$?" 2>&1 | sed 's/^/    /'
sleep 8
echo "=== mac-0, all interfaces"
k logs trace 2>&1 | sed 's/^/    /'
k delete pod t-mac t-lm trace --wait=false >/dev/null 2>&1
