#!/usr/bin/env bash
# The Linux machine's pod calling the macOS pod, five times, a few seconds
# apart, with the route each side has at the time.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
state=$("$here/../../ferry" profile | awk '$1 == "state" {print $2}')
export KUBECONFIG="$state/admin.conf"
k() { kubectl "$@"; }
mac=$(k get pod mac-web -o jsonpath='{.status.podIP}')
for i in 1 2 3 4 5; do
    printf '    try %d: ' "$i"
    k exec lm -c tcp -- sh -c "nc -w 3 $mac 8080 </dev/null || echo 'no answer'; ip route get $mac | head -1" 2>&1 | tr '\n' ' '
    echo
    sleep 4
done
grep -a "routes:" "$state/machined/mac-0.macvm.logs/runtime.log" | tail -3 | sed 's/^/    /'
