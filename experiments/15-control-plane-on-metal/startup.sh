#!/usr/bin/env bash
# How long a whole control plane takes to start on the metal: etcd, the API
# server, the controller manager and the scheduler, from nothing to /healthz
# answering "ok".
#
# Ports and state are shifted well clear of a cluster that may already be
# running on this Mac, and it tears itself down afterwards. PKI generation is
# timed separately because it happens once per cluster, not once per start.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cp="$here/../../control-plane"

export STATE="${STATE:-${TMPDIR:-/tmp}/cp-metal-state}"
export PKI_DIR="$STATE/pki"
export NODE_NAME="cp-metal-probe"
export API_PORT="${API_PORT:-19443}"
export CONTROLLER_PORT="${CONTROLLER_PORT:-19257}"
export SCHEDULER_PORT="${SCHEDULER_PORT:-19259}"
export ETCD_CLIENT_PORT="${ETCD_CLIENT_PORT:-19379}"
export ETCD_PEER_PORT="${ETCD_PEER_PORT:-19380}"
export ADVERTISE="${ADVERTISE:-127.0.0.1}"
export POD_GATEWAY="${POD_GATEWAY:-127.0.0.1}"

cleanup() { STATE="$STATE" "$cp/down.sh" >/dev/null 2>&1; }
trap cleanup EXIT

rm -rf "$STATE"
mkdir -p "$STATE"

# Once per cluster: certificates and keys.
pki_start=$(python3 -c 'import time; print(time.time())')
PKI_DIR="$PKI_DIR" NODE_NAME="$NODE_NAME" VMNET_GW="$POD_GATEWAY" "$cp/pki.sh" >/dev/null 2>&1
pki_end=$(python3 -c 'import time; print(time.time())')

# Every start: four processes, to /healthz.
up_start=$(python3 -c 'import time; print(time.time())')
"$cp/up.sh" >"$STATE/up.log" 2>&1
status=$?
up_end=$(python3 -c 'import time; print(time.time())')

if [ $status -ne 0 ]; then
  echo "control plane failed to start:"; tail -20 "$STATE/up.log"; exit 1
fi

python3 - "$pki_start" "$pki_end" "$up_start" "$up_end" <<'EOF'
import sys
pki_start, pki_end, up_start, up_end = map(float, sys.argv[1:5])
print(f"PKI_SECONDS={pki_end - pki_start:.2f}")
print(f"START_TO_HEALTHZ_SECONDS={up_end - up_start:.2f}")
EOF
