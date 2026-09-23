#!/usr/bin/env bash
# The control plane half of 'ferry upgrade apply' as it was before this
# experiment -- control-plane/down.sh, then control-plane/up.sh at the same
# version -- run under the probe, so the outage it causes can be measured
# without building a second Kubernetes to upgrade to.
#
# The environment is the one start_control_plane passes, read back from the
# running processes the first time and kept in $run/cp.env, so it cannot drift
# from what the profile actually uses.
#
#   ./restart-control-plane.sh <FERRY_HOME> <FERRY_RUN> <version> [probe-seconds]
#   MODE=up ./restart-control-plane.sh ...     just start it again
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
home="$1" run="$2" version="$3" secs="${4:-20}"
now() { python3 -c 'import time;print(time.time())'; }

arg() { # component flag
  ps -o args= -p "$(cat "$home/$1.pid")" | tr ' ' '\n' | sed -n "s/^--$2=//p" | head -1
}
if [ ! -f "$run/cp.env" ]; then
  cat > "$run/cp.env" <<ENV
API_PORT=$(arg kube-apiserver secure-port)
ETCD_CLIENT_PORT=$(arg etcd listen-client-urls | sed 's/.*://')
ETCD_PEER_PORT=$(arg etcd listen-peer-urls | sed 's/.*://')
POD_GATEWAY=$(cat "$run/cri/gateway")
ADVERTISE=$(arg kube-apiserver advertise-address)
NODE_NAME=$(cat "$run/node-name")
CLUSTER_CIDR=$(arg kube-controller-manager cluster-cidr)
CONTROLLER_PORT=$(arg kube-controller-manager secure-port)
SCHEDULER_PORT=$(arg kube-scheduler secure-port)
SERVICE_NODE_PORT_RANGE=$(arg kube-apiserver service-node-port-range)
ENV
fi
set -a
# shellcheck disable=SC1091
. "$run/cp.env"
K8S_VERSION="$version" STATE="$home"
set +a

if [ "${MODE:-}" = up ]; then
  "$repo/control-plane/up.sh" >"$run/logs/control-plane.log" 2>&1
  exit
fi

probe="${PROBE:-${TMPDIR:-/tmp}/ferry-probe}"
[ -x "$probe" ] || ( cd "$here/probe" && go build -o "$probe" . )
"$probe" -home "$home" -port "$API_PORT" -for "${secs}s" > "$run/probe.out" &
probe_pid=$!
sleep 2
t0=$(now)
case "${MODE:-restart}" in
  restart)
    # Everything stopped, then everything started: what apply did before.
    "$repo/control-plane/down.sh"
    cp "$home/logs/kube-apiserver.log" "$run/logs/kube-apiserver.shutdown.log"
    t_mid=$(now)
    echo "down.sh took $(python3 -c "print(round($t_mid - $t0, 2))")s"
    "$repo/control-plane/up.sh" >"$run/logs/control-plane.log" 2>&1 ;;
  keep-etcd)
    # The API server and friends stopped and started; etcd left running.
    COMPONENTS="kube-scheduler kube-controller-manager kube-apiserver" "$repo/control-plane/down.sh"
    FERRY_KEEP_ETCD=1 "$repo/control-plane/up.sh" >"$run/logs/control-plane.log" 2>&1 ;;
  handover)
    # The new API server beside the old one, etcd left running.
    FERRY_KEEP_ETCD=1 FERRY_HANDOVER=1 FERRY_HANDOVER_BIN="$repo/bin/ferry-handover" "$repo/control-plane/up.sh" >"$run/logs/control-plane.log" 2>&1 ;;
esac
t1=$(now)
echo "${MODE:-restart} took $(python3 -c "print(round($t1 - $t0, 2))")s"
grep -E '^\s+[-+=!.]' "$run/logs/control-plane.log" | sed 's/^/  /'
wait "$probe_pid" || true
cat "$run/probe.out"
