#!/usr/bin/env bash
# Does one kernel cache a shared image once, or once per container?
#
# The matrix could not answer this: both shapes ran out of guest memory before
# they ran out of image, so both totals were the cap rather than the demand.
# This gives each shape more memory than it can possibly want and looks at what
# it actually takes.
#
#   one container, 4 GiB      -> what a single container's demand is, D
#   eight containers, 12 GiB  -> D if the cache is shared, 8 x D if it is not
#
# Ferry clones an ext4 per container, so the prediction is 8 x D: same bytes,
# eight block devices, eight sets of cache entries. If that is what comes out,
# a shared kernel saves the per-VM overhead and nothing else, and image-layer
# sharing is a separate piece of work rather than a thing that comes for free.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

RESULTS="${RESULTS:-$here/results}"
mkdir -p "$RESULTS"
SHK="$here/build/shkcost"
FAT="${FAT:-docker.io/library/python:3.12}"

run() { # count mib tag
  local count=$1 mib=$2 tag=$3
  echo
  echo "=============== $tag ($count containers, ${mib} MiB VM) ==============="
  ./runtime.sh stop >/dev/null 2>&1
  sleep 3
  POD_MEMORY_MIB=$mib ./runtime.sh start >/dev/null 2>&1
  "$SHK" -shape shared-vm -count "$count" -workload touch -image "$FAT" \
    -hold 90s -sample 10s -state shk-cri-state -out "$RESULTS/$tag.json"
  sleep 5
}

run 1 4096  "dedup-python-1-shared-vm"
run 8 12288 "dedup-python-8-shared-vm"

./runtime.sh stop >/dev/null 2>&1
sleep 3
./runtime.sh start >/dev/null 2>&1
echo done
