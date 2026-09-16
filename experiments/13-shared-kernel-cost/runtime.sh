#!/usr/bin/env bash
# Starts a ferry-cri of this experiment's own, on its own socket, state
# directory and pod subnet, so the measurement never touches a cluster that
# happens to be running on the same Mac. No streamer, no proxyd, no netpol, no
# GPU: this measures VMs and containers, and nothing else should be in the way.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"

STATE="${STATE:-${TMPDIR:-/tmp}/shk-cri-state}"
SOCK="${SOCK:-/tmp/shk-cri.sock}"
LOG="${LOG:-$STATE/ferry-cri.log}"
# Prefer a locally built runtime; fall back to the one the checkout already
# built, since the VM and container paths this measures are the same code.
CRI="${CRI:-$root/bin/ferry-cri}"
[ -x "$CRI" ] || CRI="$HOME/ferry/bin/ferry-cri"
KERNEL="${KERNEL:-$root/kernel/vmlinux-arm64}"
[ -f "$KERNEL" ] || KERNEL="$HOME/ferry/kernel/vmlinux-arm64"

case "${1:-start}" in
start)
  if [ -S "$SOCK" ] && pgrep -f "ferry-cri --endpoint $SOCK" >/dev/null; then
    echo "already running on $SOCK"; exit 0
  fi
  mkdir -p "$STATE"
  rm -f "$SOCK"
  echo "==> ferry-cri: $CRI"
  echo "    kernel:    $KERNEL"
  echo "    state:     $STATE"
  "$CRI" \
    --endpoint "$SOCK" \
    --state "$STATE" \
    --kernel "$KERNEL" \
    --pod-subnet auto \
    --pod-cpus 2 \
    --pod-memory-mib "${POD_MEMORY_MIB:-512}" \
    --exec-socket /tmp/shk-exec.sock \
    --streamer-control /tmp/shk-streamer.sock \
    >"$LOG" 2>&1 &
  echo $! >"$STATE/ferry-cri.pid"
  for _ in $(seq 1 60); do
    if [ -S "$SOCK" ] && grep -q "serving" "$LOG" 2>/dev/null; then
      grep -E "network|serving" "$LOG" | tail -2
      echo "==> up on $SOCK"; exit 0
    fi
    sleep 0.5
  done
  echo "failed to start:"; tail -20 "$LOG"; exit 1
  ;;
stop)
  [ -f "$STATE/ferry-cri.pid" ] && kill "$(cat "$STATE/ferry-cri.pid")" 2>/dev/null || true
  pkill -f "ferry-cri --endpoint $SOCK" 2>/dev/null || true
  echo "stopped"
  ;;
log)
  tail -"${2:-40}" "$LOG"
  ;;
*)
  echo "usage: $0 [start|stop|log]"; exit 1
  ;;
esac
