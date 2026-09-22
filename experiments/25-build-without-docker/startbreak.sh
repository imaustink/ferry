#!/usr/bin/env bash
# Where a cold builder start actually goes.
#
# The battery's `start` column was not quotable for ferry: the manifests forced
# imagePullPolicy: Always to work around the digest bug, so every start
# included a re-pull, and the readings ran from 1.2 s to 104 s depending on
# what the registry did. With the bug fixed the pull can be left out, and the
# question becomes worth asking properly -- because "keep the builder warm" is
# a much weaker recommendation if starting one is cheap.
#
# Four phases, from the pod's own timestamps and the kubelet's events:
#
#   scheduled    apply -> the scheduler picked a node
#   image        the kubelet deciding it has the image (or fetching it)
#   created      ext4 unpack + VM boot + the container existing
#   ready        buildkitd listening and answering buildctl
#
# The first three come from the API server, which timestamps to the second --
# too coarse to split, so they are reported as one and the wall clock carries
# the precision. What the phases are for is telling a pull apart from a boot.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/lib.sh"

MANIFEST="${BUILDER_MANIFEST:-buildkitd-sized.yaml}"
RUNS="${RUNS:-5}"
POLICY="${POLICY:-IfNotPresent}"

# The manifests in the repo carry the Always workaround. This rewrites the
# policy on the way in so the same file can be measured both ways -- the
# comparison between them is the cost of the pull.
manifest() {
  sed "s/imagePullPolicy: .*/imagePullPolicy: $POLICY/" "$here/manifests/$MANIFEST"
}

echo "=== cold builder start, $MANIFEST, imagePullPolicy: $POLICY, $RUNS runs"
echo

total=0
for i in $(seq 1 "$RUNS"); do
  kc delete pod buildkitd --ignore-not-found --wait=true >/dev/null 2>&1
  sleep 3

  t0=$(now_ms)
  manifest | kc apply -f - >/dev/null 2>&1

  # Split the wait in two. Everything up to Running is ferry's -- scheduling,
  # the image, the ext4, the VM. Everything after it is buildkitd's own
  # startup, which no substrate choice can do anything about.
  running=0
  for _ in $(seq 1 6000); do
    [ "$(kc get pod buildkitd -o jsonpath='{.status.phase}' 2>/dev/null)" = Running ] && break
    sleep 0.05
  done
  running=$(( $(now_ms) - t0 ))

  ferry_await_ready ferry 300
  rc=$?
  ms=$(( $(now_ms) - t0 ))

  if [ $rc -ne 0 ]; then
    echo "  run $i: never became ready"
    kc get pod buildkitd -o wide
    continue
  fi

  printf '  run %d  %6s ms to Running  %6s ms to answering  (buildkitd itself: %s ms)\n' \
    "$i" "$running" "$ms" "$((ms - running))"
  record "start-$POLICY" "run$i" "$ms"
  record "start-$POLICY" "run$i-running" "$running"
  total=$((total + ms))
done

echo
printf '  mean over %d runs: %s ms\n' "$RUNS" "$((total / RUNS))"
record "start-$POLICY" mean "$((total / RUNS))"
