#!/usr/bin/env bash
run="${RUNDIR:-/tmp/ferry-e02}"
for p in kubelet fakecri; do
  [ -f "$run/$p.pid" ] && kill -TERM "$(cat "$run/$p.pid")" 2>/dev/null && echo "    - $p"
done
