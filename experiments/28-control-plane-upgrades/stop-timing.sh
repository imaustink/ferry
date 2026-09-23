#!/usr/bin/env bash
# How long each control plane process takes to exit on SIGTERM, one at a time
# in down.sh's order, with no deadline -- down.sh's ten seconds of patience
# hides how long the API server would really take.
#
#   ./stop-timing.sh <FERRY_HOME>
set -uo pipefail
home="$1"
ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
for c in kube-scheduler kube-controller-manager kube-apiserver etcd; do
  [ -f "$home/$c.pid" ] || continue
  p="$(cat "$home/$c.pid")"
  t0="$(ms)"
  kill -TERM "$p" 2>/dev/null
  while kill -0 "$p" 2>/dev/null; do sleep 0.02; done
  echo "$c exited $(( $(ms) - t0 ))ms after SIGTERM"
  rm -f "$home/$c.pid"
done
