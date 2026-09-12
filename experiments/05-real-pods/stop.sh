#!/usr/bin/env bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
run="${RUNDIR:-/tmp/ferry-e05}"
for p in kubelet ferry-cri; do
  pidfile="$run/$p.pid"
  [ -f "$pidfile" ] || continue
  pid="$(cat "$pidfile")"
  kill -TERM "$pid" 2>/dev/null || continue
  echo "    - $p"
  # ferry-cri must finish releasing its vmnet network before another one can
  # claim the same subnet, so wait for the process to actually be gone.
  for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
  kill -KILL "$pid" 2>/dev/null
done
pkill -f "bin/ferry-cri" 2>/dev/null
sleep 1
"$here/../../control-plane/down.sh"
