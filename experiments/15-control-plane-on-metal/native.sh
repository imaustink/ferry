#!/usr/bin/env bash
# etcd on the metal: the same version, the same benchmark, run as a darwin/arm64
# process against APFS directly.
#
# etcd is the right component to measure. Everything else in a control plane is
# CPU and memory, and a hardware-virtualised guest runs those at close to native
# speed; what a VM changes is the storage path, and etcd is the only part of the
# control plane that cares — every write goes through a WAL fsync before the API
# server may answer.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

ETCD="${ETCD:-$HOME/ferry/bin/etcd}"
ETCDCTL="${ETCDCTL:-$HOME/ferry/bin/etcdctl}"
DATA="${DATA:-${TMPDIR:-/tmp}/cp-metal-etcd}"
LOAD="${LOAD:-s}"

[ -x "$ETCD" ] || { echo "no etcd at $ETCD"; exit 1; }
rm -rf "$DATA"; mkdir -p "$DATA"

"$ETCD" --data-dir "$DATA" \
  --listen-client-urls http://127.0.0.1:23790 \
  --advertise-client-urls http://127.0.0.1:23790 \
  --listen-peer-urls http://127.0.0.1:23800 \
  --initial-advertise-peer-urls http://127.0.0.1:23800 \
  --initial-cluster default=http://127.0.0.1:23800 \
  --log-level error >"$DATA/etcd.log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null' EXIT

# Poll at the same 50ms granularity the in-VM side uses, so "time to ready" is
# measured the same way in both places rather than two different ways.
export ETCDCTL_API=3
n=0
until "$ETCDCTL" --endpoints http://127.0.0.1:23790 endpoint health >/dev/null 2>&1; do
  n=$((n + 1))
  [ "$n" -gt 600 ] && { echo "etcd never became healthy"; tail -5 "$DATA/etcd.log"; exit 1; }
  sleep 0.05
done
echo "READY_MS=$((n * 50))"

"$ETCDCTL" --endpoints http://127.0.0.1:23790 check perf --load="$LOAD" 2>&1 | sed 's/^/PERF /'

# Mean WAL fsync and backend commit, straight from etcd's own histograms. The
# mean rather than a percentile because summing buckets in shell is a worse
# source of error than the averaging is.
curl -s http://127.0.0.1:23790/metrics | awk '
  /^etcd_disk_wal_fsync_duration_seconds_sum/ {s=$2}
  /^etcd_disk_wal_fsync_duration_seconds_count/ {c=$2}
  /^etcd_disk_backend_commit_duration_seconds_sum/ {bs=$2}
  /^etcd_disk_backend_commit_duration_seconds_count/ {bc=$2}
  END {
    if (c > 0) printf "FSYNC_MEAN_MS=%.3f fsyncs=%d\n", s*1000/c, c
    if (bc > 0) printf "COMMIT_MEAN_MS=%.3f commits=%d\n", bs*1000/bc, bc
  }'
