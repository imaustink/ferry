#!/usr/bin/env bash
# What is a starting control plane waiting for?
#
# Start-to-/healthz turned out to be far slower than the parts suggest, and it
# is not fsync — the same start with durability disabled takes the same time.
# This polls the API server's own verbose health output once a second and
# reports which checks are failing, so the wait is attributed rather than
# guessed at.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cp="$here/../../control-plane"

export STATE="${STATE:-${TMPDIR:-/tmp}/cp-diag-state}"
export PKI_DIR="$STATE/pki"
export NODE_NAME="cp-diag-probe"
export API_PORT="${API_PORT:-19543}"
export CONTROLLER_PORT="${CONTROLLER_PORT:-19357}"
export SCHEDULER_PORT="${SCHEDULER_PORT:-19359}"
export ETCD_CLIENT_PORT="${ETCD_CLIENT_PORT:-19479}"
export ETCD_PEER_PORT="${ETCD_PEER_PORT:-19480}"
export ADVERTISE="${ADVERTISE:-127.0.0.1}"
export POD_GATEWAY="${POD_GATEWAY:-127.0.0.1}"

cleanup() { STATE="$STATE" "$cp/down.sh" >/dev/null 2>&1; }
trap cleanup EXIT

rm -rf "$STATE"; mkdir -p "$STATE"
"$cp/up.sh" >"$STATE/up.log" 2>&1 &
up_pid=$!
start=$(python3 -c 'import time; print(time.time())')

elapsed() { python3 -c "import time; print(f'{time.time() - $start:6.1f}s')"; }

seen=""
for _ in $(seq 1 180); do
  if [ -f "$STATE/admin.conf" ]; then
    body="$(KUBECONFIG=$STATE/admin.conf kubectl get --raw '/healthz?verbose' 2>&1)"
    # Only the failures, and only when the set of them changes, so the output is
    # a timeline of what cleared rather than 180 copies of the same list.
    bad="$(printf '%s' "$body" | grep -E '^\[-\]' | tr '\n' ' ')"
    if [ "$bad" != "$seen" ]; then
      echo "$(elapsed)  ${bad:-all checks passing}"
      seen="$bad"
    fi
    if printf '%s' "$body" | grep -q "healthz check passed"; then
      echo "$(elapsed)  /healthz ok"
      # up.sh does one kubectl apply after this point. Discovery on a fresh API
      # server is the other candidate for the missing minute, so time it rather
      # than assume the wait loop is where the time goes.
      plain="$(KUBECONFIG=$STATE/admin.conf kubectl get --raw /healthz 2>&1)"
      echo "$(elapsed)  'kubectl get --raw /healthz' returned [$plain]"
      KUBECONFIG=$STATE/admin.conf kubectl apply -f - >/dev/null 2>&1 <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: startup-probe
  namespace: default
YAML
      echo "$(elapsed)  kubectl apply finished"
      break
    fi
  else
    echo "$(elapsed)  waiting for admin.conf"
  fi
  sleep 1
done

wait $up_pid 2>/dev/null
echo "$(elapsed)  up.sh returned"
