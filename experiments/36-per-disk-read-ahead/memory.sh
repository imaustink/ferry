#!/usr/bin/env bash
# Host footprint per pod against the read-ahead of the pod's own disks (image
# and scratch; the init disk stays at 128 KiB), for three workloads. COUNT
# pods a cell, REPS passes with the values interleaved.
#   memory.sh [REPS] [COUNT] ["read-ahead values"] ["workloads"]
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
image() {
  case $1 in
  alpine) echo ghcr.io/linuxcontainers/alpine:3.20 ;;
  python) echo docker.io/library/python:3.12-slim ;;
  nginx) echo docker.io/library/nginx:1.27-alpine ;;
  node) echo docker.io/library/node:22-alpine ;;
  esac
}
for rep in $(seq 1 "${1:-2}"); do
  for ra in ${3:-128 1024 2048 4096 8192}; do
    for wl in ${4:-alpine python nginx}; do
      label="mem-$wl-$ra-$rep"
      EXTRA="--pod-read-ahead-kb $ra ${EXTRA:-}" HOLD="${HOLD:-30s}" "$here/measure.sh" "$label" "${2:-4}" custom \
        -cmd-file "$here/app-$wl.sh" -image "$(image "$wl")" -log-grep "P|" >/dev/null 2>&1
      python3 - "$here/results/$label.json" "rep=$rep ra=$ra wl=$wl" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
served = sum("P| served" in l for l in d.get("logs") or [])
print(f"{sys.argv[2]} footprint {d['footprint_mib'] / d['count']:.1f} start {d['create_seconds']:.2f}s served {served}/{d['count']}")
EOF
    done
  done
done
