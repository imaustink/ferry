#!/usr/bin/env bash
# The comparison that matters: an edit, and a cluster running it.
#
# The battery in bench.sh held the handoff still on purpose -- every stack
# exported an OCI tarball and every stack loaded it with `ferry image load` --
# so that it measured substrates and not workflows. That was the right call for
# that question and it is the wrong one for this one, because nobody using
# Docker for Kubernetes development loads their image with `ferry image load`.
# They run `kind load docker-image`, and that is a copy into a different VM
# over a different path.
#
# So this times the two real workflows, from an edited source file to a cluster
# that can run the result:
#
#   ferry    ferry image build -t x <ctx>
#   docker   docker buildx build --load -t x <ctx>  &&  kind load docker-image x
#
# Both builders are warm and both caches are hot, which is the state a dev loop
# actually lives in. The edit is a one-line change below the expensive step, so
# the build itself is nearly free in both and what is left is the handoff.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/lib.sh"

WORKLOAD="${1:-node}"
RUNS="${RUNS:-3}"
CLUSTER="${CLUSTER:-buildbench}"
FERRY_BIN="$(cd "$here/../.." && pwd)/ferry"

case "$WORKLOAD" in
  tiny) EDIT=payload ;;
  node) EDIT=src/index.js ;;
  fat)  EDIT=src/main.py ;;
  *) echo "unknown workload $WORKLOAD" >&2; exit 2 ;;
esac

ctx="$SCRATCH/loop-$WORKLOAD"
rm -rf "$ctx"; cp -R "$here/workloads/$WORKLOAD" "$ctx"

echo "=== $WORKLOAD: an edit, to a cluster that can run it ($RUNS runs)"
echo

# Warm both sides first: a cold cache on either would measure the registry.
echo "  priming..."
"$FERRY_BIN" image build -q -t "loop-$WORKLOAD:dev" "$ctx" >/dev/null 2>&1
docker --context "$DOCKER_CTX" buildx build --load -t "loop-$WORKLOAD:dev" "$ctx" >/dev/null 2>&1
echo

for i in $(seq 1 "$RUNS"); do
  date +%s%N > "$ctx/$EDIT"

  t0=$(now_ms)
  "$FERRY_BIN" image build -q -t "loop-$WORKLOAD:dev" "$ctx" >/dev/null 2>&1
  f=$(( $(now_ms) - t0 ))

  date +%s%N > "$ctx/$EDIT"

  t0=$(now_ms)
  docker --context "$DOCKER_CTX" buildx build --load -t "loop-$WORKLOAD:dev" "$ctx" >/dev/null 2>&1
  d_build=$(( $(now_ms) - t0 ))
  kind load docker-image "loop-$WORKLOAD:dev" --name "$CLUSTER" >/dev/null 2>&1
  d=$(( $(now_ms) - t0 ))

  printf '  run %d   ferry %6s ms   docker+kind %6s ms  (build %s + load %s)\n' \
    "$i" "$f" "$d" "$d_build" "$((d - d_build))"
  record "loop-$WORKLOAD" "run$i-ferry" "$f"
  record "loop-$WORKLOAD" "run$i-docker" "$d"
  record "loop-$WORKLOAD" "run$i-docker-build" "$d_build"
done
