#!/usr/bin/env bash
# The same etcd, the same benchmark, inside a pod VM — which is the storage path
# a control plane would have if it ran on a Linux machine instead of on the Mac.
#
# The binary is fetched from the etcd release rather than taken from a container
# image, because it has to be the same version as the one on the metal and the
# published etcd images carry no shell to drive a benchmark with.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
harness="$here/../13-shared-kernel-cost"

VERSION="${VERSION:-3.6.5}"
LOAD="${LOAD:-s}"
URL="https://github.com/etcd-io/etcd/releases/download/v$VERSION/etcd-v$VERSION-linux-arm64.tar.gz"

read -r -d '' SCRIPT <<EOF
wget -qO /tmp/e.tgz $URL || { echo "DOWNLOAD_FAILED"; sleep 300; }
tar xzf /tmp/e.tgz -C /tmp
cd /tmp/etcd-v$VERSION-linux-arm64
mkdir -p /var/lib/etcd
./etcd --data-dir /var/lib/etcd \
  --listen-client-urls http://127.0.0.1:2379 \
  --advertise-client-urls http://127.0.0.1:2379 \
  --log-level error >/tmp/etcd.log 2>&1 &
n=0
until ./etcdctl endpoint health >/dev/null 2>&1; do
  n=\$((n+1))
  [ \$n -gt 600 ] && { echo "NEVER_HEALTHY"; tail -5 /tmp/etcd.log; sleep 300; }
  usleep 50000
done
echo "READY_MS=\$((n*50))"
./etcdctl check perf --load=$LOAD 2>&1 | sed 's/^/PERF /'
wget -qO- http://127.0.0.1:2379/metrics | awk '
  /^etcd_disk_wal_fsync_duration_seconds_sum/ {s=\$2}
  /^etcd_disk_wal_fsync_duration_seconds_count/ {c=\$2}
  /^etcd_disk_backend_commit_duration_seconds_sum/ {bs=\$2}
  /^etcd_disk_backend_commit_duration_seconds_count/ {bc=\$2}
  END {
    if (c > 0) printf "FSYNC_MEAN_MS=%.3f fsyncs=%d\n", s*1000/c, c
    if (bc > 0) printf "COMMIT_MEAN_MS=%.3f commits=%d\n", bs*1000/bc, bc
  }'
sleep 300
EOF

exec "$harness/build/shkcost" \
  -count 1 -shape vm-per-pod -workload custom \
  -image ghcr.io/linuxcontainers/alpine:3.20 \
  -cmd "$SCRIPT" \
  -log-grep "=" \
  -hold "${HOLD:-150s}" -sample 60s -state shk-cri-state
