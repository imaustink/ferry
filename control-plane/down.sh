#!/usr/bin/env bash
# Stops the control plane. State under $STATE is left alone; use --purge to
# drop etcd's data directory as well.
set -uo pipefail
STATE="${STATE:-/tmp/ferry}"
# etcd and the API server do not always exit on SIGTERM promptly, so wait for
# each one and escalate rather than reporting a stop that did not happen.
#
# Unless the data is going anyway. With --purge, $STATE/etcd is deleted a few
# lines below, and the API server's graceful shutdown -- draining watches,
# finishing in-flight requests -- is then two seconds of a mode 1 teardown and
# five of a mode 2 one, spent settling state that is about to be removed.
# Measured: scheduler and controller-manager exit in 0ms, the API server takes
# 2.2s in mode 1, and in mode 2 it reaches the full grace and is killed
# anyway. So on --purge it is killed at once, deliberately, rather than
# politely and then killed.
#
# Without --purge the cluster is meant to come back, so the drain stays: etcd
# gets to finish writing, and SIGKILLing it is how a data directory needs a
# restore.
PURGE=""
[ "${1:-}" = "--purge" ] && PURGE=1

for name in kube-scheduler kube-controller-manager kube-apiserver etcd; do
  pidfile="$STATE/$name.pid"
  [ -f "$pidfile" ] || continue
  pid="$(cat "$pidfile")"
  rm -f "$pidfile"
  if [ -n "$PURGE" ]; then
    kill -KILL "$pid" 2>/dev/null && echo "    - $name (pid $pid, purging)"
    continue
  fi
  kill -TERM "$pid" 2>/dev/null || continue
  # 50ms, not 500: these mostly exit immediately and the tick was the cost.
  # Same ten seconds of patience before escalating.
  i=0
  while [ "$i" -lt 200 ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null
    echo "    - $name (pid $pid, forced)"
  else
    echo "    - $name (pid $pid)"
  fi
done
if [ -n "$PURGE" ]; then rm -rf "$STATE/etcd"; echo "    purged etcd data"; fi
