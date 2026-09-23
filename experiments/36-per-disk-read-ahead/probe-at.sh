#!/usr/bin/env bash
# Runs a probe script in COUNT privileged pods and prints what it printed.
#   probe-at.sh LABEL PROBE [COUNT]      (EXTRA, IMAGE, HOLD as measure.sh)
here="$(cd "$(dirname "$0")" && pwd)"
STATE="${STATE:-${TMPDIR:-/tmp}/e36-cri-state}"
FERRY_CRI_TRACE=1 HOLD="${HOLD:-30s}" "$here/measure.sh" "$1" "${3:-1}" custom -cmd-file "$here/$2" \
  -image "${IMAGE:-ghcr.io/linuxcontainers/alpine:3.20}" -privileged -log-grep "P|" | grep -E "footprint|running in"
grep -hE "trace     (read-ahead|boot)|warning" "$STATE/ferry-cri.log" | head -"${TRACE_LINES:-6}"
python3 - "$here/results/$1.json" <<'EOF'
import json, sys
for line in json.load(open(sys.argv[1])).get("logs") or []:
    print(line.split(" stdout F ", 1)[-1])
EOF
