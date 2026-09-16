#!/usr/bin/env bash
# The shared-VM cells again, with the VM sized to what the pods it replaces
# would have had between them: N containers that would each have run in a
# 512 MiB VM get one VM of N x 512 MiB.
#
# Without this the comparison is rigged in the wrong direction -- 24 containers
# sharing a single 512 MiB kernel are not "denser", they are starved -- and
# since guest memory is lazily backed, the larger configuration costs nothing
# that is not actually touched.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

RESULTS="${RESULTS:-$here/results}"
mkdir -p "$RESULTS"
SHK="$here/build/shkcost"
SMALL="${SMALL:-ghcr.io/linuxcontainers/alpine:3.20}"
FAT="${FAT:-docker.io/library/python:3.12}"

cell() { # count workload image hold tag
  local count=$1 workload=$2 image=$3 hold=$4 tag=$5
  local mib=$((count * 512))
  echo
  echo "=============== $tag (VM: ${mib} MiB) ==============="
  ./runtime.sh stop >/dev/null 2>&1
  sleep 3
  POD_MEMORY_MIB=$mib ./runtime.sh start | tail -2
  "$SHK" -shape shared-vm -count "$count" -workload "$workload" -image "$image" \
    -hold "$hold" -sample 5s -state shk-cri-state -out "$RESULTS/$tag.json"
  sleep 5
}

cell 8  idle   "$SMALL" 20s "fair-idle-alpine-8-shared-vm"
cell 20 idle   "$SMALL" 20s "fair-idle-alpine-20-shared-vm"
cell 8  touch  "$SMALL" 30s "fair-touch-alpine-8-shared-vm"
cell 20 touch  "$SMALL" 30s "fair-touch-alpine-20-shared-vm"
cell 8  touch  "$FAT"   90s "fair-touch-python-8-shared-vm"
cell 8  reread "$SMALL" 45s "fair-reread-alpine-8-shared-vm"

./runtime.sh stop >/dev/null 2>&1
sleep 3
./runtime.sh start | tail -1
echo
echo "results in $RESULTS"
