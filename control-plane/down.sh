#!/usr/bin/env bash
# Stops the control plane. State under $STATE is left alone; use --purge to
# drop etcd's data directory as well.
set -uo pipefail
STATE="${STATE:-/tmp/ferry}"
# etcd and the API server do not always exit on SIGTERM promptly, so wait for
# each one and escalate rather than reporting a stop that did not happen.
for name in kube-scheduler kube-controller-manager kube-apiserver etcd; do
  pidfile="$STATE/$name.pid"
  [ -f "$pidfile" ] || continue
  pid="$(cat "$pidfile")"
  rm -f "$pidfile"
  kill -TERM "$pid" 2>/dev/null || continue
  for _ in $(seq 1 10); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null
    echo "    - $name (pid $pid, forced)"
  else
    echo "    - $name (pid $pid)"
  fi
done
if [ "${1:-}" = "--purge" ]; then rm -rf "$STATE/etcd"; echo "    purged etcd data"; fi
