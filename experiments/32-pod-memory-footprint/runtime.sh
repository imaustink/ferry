#!/usr/bin/env bash
# A ferry-cri of this experiment's own, on its own socket, state directory and
# pod subnet: no kubelet, no streamer, nothing reconciling behind the numbers.
# CRI, KERNEL, POD_MEMORY_MIB, POD_CPUS and EXTRA pick the variant under test.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
STATE="${STATE:-${TMPDIR:-/tmp}/e32-cri-state}"
SOCK="${SOCK:-/tmp/e32-cri.sock}"
LOG="$STATE/ferry-cri.log"
CRI="${CRI:-$root/bin/ferry-cri}"
KERNEL="${KERNEL:-$root/kernel/vmlinux-arm64}"
case "${1:-start}" in
start)
  mkdir -p "$STATE"; rm -f "$SOCK"
  # shellcheck disable=SC2086
  "$CRI" --endpoint "$SOCK" --state "$STATE" --kernel "$KERNEL" \
    --pod-subnet auto --pod-cpus "${POD_CPUS:-2}" --pod-memory-mib "${POD_MEMORY_MIB:-512}" \
    --exec-socket /tmp/e32-exec.sock --streamer-control /tmp/e32-streamer.sock \
    ${EXTRA:-} >"$LOG" 2>&1 &
  echo $! >"$STATE/ferry-cri.pid"
  for _ in $(seq 1 120); do
    if [ -S "$SOCK" ] && grep -q "serving" "$LOG" 2>/dev/null; then echo "==> up ($CRI, $KERNEL)"; exit 0; fi
    sleep 0.5
  done
  echo "failed to start:"; tail -20 "$LOG"; exit 1 ;;
stop)
  [ -f "$STATE/ferry-cri.pid" ] && kill "$(cat "$STATE/ferry-cri.pid")" 2>/dev/null || true
  sleep 2; echo stopped ;;
esac
