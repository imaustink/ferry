#!/usr/bin/env bash
# Stops the control plane. State under $STATE is left alone; use --purge to
# drop etcd's data directory as well.
set -uo pipefail
STATE="${STATE:-/tmp/k5s}"
for name in kube-scheduler kube-controller-manager kube-apiserver etcd; do
  pidfile="$STATE/$name.pid"
  [ -f "$pidfile" ] || continue
  pid="$(cat "$pidfile")"
  if kill -TERM "$pid" 2>/dev/null; then echo "    - $name (pid $pid)"; fi
  rm -f "$pidfile"
done
sleep 1
if [ "${1:-}" = "--purge" ]; then rm -rf "$STATE/etcd"; echo "    purged etcd data"; fi
