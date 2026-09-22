#!/usr/bin/env bash
# Which of the three waits after "Running" is the slow one.
#
# startbreak.sh showed ferry's half of a cold builder start is 614-668 ms and
# rock steady, while the wait between Running and buildctl answering ran 109 ms,
# 3.08 s, 41 s and 162 s across six runs of the same thing. buildkitd's own log
# says it goes from first line to "running server on [::]:1234" in 44 ms, so it
# is not buildkitd starting.
#
# That leaves three candidates, and they are separable:
#
#   ip        the API server publishing the pod's address
#   tcp       the Mac being able to open a socket to it
#   buildctl  buildctl completing a request over that socket
#
# Each is polled on its own clock from the moment the pod reports Running.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/lib.sh"

MANIFEST="${BUILDER_MANIFEST:-buildkitd-sized.yaml}"
RUNS="${RUNS:-6}"

manifest() { sed 's/imagePullPolicy: .*/imagePullPolicy: IfNotPresent/' "$here/manifests/$MANIFEST"; }

echo "=== after Running, what are we waiting for ($RUNS runs)"
echo

for i in $(seq 1 "$RUNS"); do
  kc delete pod buildkitd --ignore-not-found --wait=true >/dev/null 2>&1
  sleep 3
  manifest | kc apply -f - >/dev/null 2>&1

  for _ in $(seq 1 6000); do
    [ "$(kc get pod buildkitd -o jsonpath='{.status.phase}' 2>/dev/null)" = Running ] && break
    sleep 0.05
  done
  t0=$(now_ms)

  ip=""
  for _ in $(seq 1 6000); do
    ip="$(kc get pod buildkitd -o jsonpath='{.status.podIP}' 2>/dev/null)"
    [ -n "$ip" ] && break
    sleep 0.05
  done
  t_ip=$(( $(now_ms) - t0 ))

  # A plain TCP open, with a short timeout so a hung connect is retried rather
  # than waited on. This is the wire, with no gRPC on top of it.
  for _ in $(seq 1 6000); do
    nc -z -G 1 -w 1 "$ip" 1234 >/dev/null 2>&1 && break
    sleep 0.05
  done
  t_tcp=$(( $(now_ms) - t0 ))

  for _ in $(seq 1 6000); do
    buildctl --addr "tcp://$ip:1234" debug workers >/dev/null 2>&1 && break
    sleep 0.05
  done
  t_ctl=$(( $(now_ms) - t0 ))

  printf '  run %d  ip %5s ms   tcp %6s ms   buildctl %6s ms   (%s)\n' \
    "$i" "$t_ip" "$t_tcp" "$t_ctl" "$ip"
  record reachability "run$i-ip" "$t_ip"
  record reachability "run$i-tcp" "$t_tcp"
  record reachability "run$i-buildctl" "$t_ctl"
done
