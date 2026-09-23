#!/usr/bin/env bash
# Samples a pod once a second: its IP, and each container's restart count,
# state, start time and last termination.
#   watch.sh <pod> <seconds>
pod=${1:-crash2}
dur=${2:-90}
end=$(( $(date +%s) + dur ))
while [ "$(date +%s)" -lt "$end" ]; do
  kubectl get pod "$pod" -o json 2>/dev/null | python3 -c '
import json, sys, time
p = json.load(sys.stdin)
st = {c["name"]: c for c in p["status"].get("containerStatuses", [])}
def s(n):
    c = st[n]; state = c.get("state", {}); k = next(iter(state), "-")
    return "%s r=%s %s start=%s last=%s" % (
        n, c.get("restartCount"), k, state.get(k, {}).get("startedAt", "-")[11:19],
        c.get("lastState", {}).get("terminated", {}).get("finishedAt", "-")[11:19])
print(time.strftime("%H:%M:%S"), p["status"].get("podIP"), " | ".join(s(n) for n in sorted(st)))
'
  sleep 1
done
