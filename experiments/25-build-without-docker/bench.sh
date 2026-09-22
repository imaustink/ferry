#!/usr/bin/env bash
# One cell: a substrate, a workload, every phase that has its own answer.
#
#   ./bench.sh <ferry|docker|colima> <tiny|node|fat>
#
# Phases are separated rather than blended, because the blended number hides
# which substrate is actually being chosen between. A cold build is mostly the
# workload -- npm and pip do not care whose kernel they are on -- while the
# export and the load scale with image size and are entirely the substrate's
# business, and the incremental build is what the day actually feels like.
#
#   start        nothing -> a daemon that answers
#   cold-build   cache pruned, build only, nothing exported
#   cold-export  the same result written out as an OCI tarball
#   cold-load    that tarball into ferry's image store
#   incr-build   one source file edited, everything above it cached
#   incr-export  and exported again
#   incr-load    and loaded again
#   noop         nothing changed at all
#   idle-mem     what the warm builder costs while it does nothing
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/lib.sh"

STACK="${1:?usage: bench.sh <ferry|docker|colima> <tiny|node|fat>}"
WORKLOAD="${2:?usage: bench.sh <ferry|docker|colima> <tiny|node|fat>}"
# TAG_SUFFIX keeps two configurations of one stack apart in raw.tsv -- the
# default-sized ferry builder and the sized one, which are different answers to
# a question the feature has to settle.
TAG="$STACK${TAG_SUFFIX:+-$TAG_SUFFIX}-$WORKLOAD"

# The file the incremental cell edits, per workload. It sits below the
# expensive step in every Dockerfile here, so the edit is a cache hit on
# everything that matters and a miss on one COPY.
case "$WORKLOAD" in
  tiny) EDIT=payload ;;
  node) EDIT=src/index.js ;;
  fat)  EDIT=src/main.py ;;
  *) echo "unknown workload $WORKLOAD" >&2; exit 2 ;;
esac

ctx="$SCRATCH/ctx-$WORKLOAD"
rm -rf "$ctx"
cp -R "$here/workloads/$WORKLOAD" "$ctx"
tar="$SCRATCH/$TAG.tar"

phase() { # key command...
  local key="$1"; shift
  local t0; t0=$(now_ms)
  "$@"
  local rc=$? ms; ms=$(ms_since "$t0")
  if [ $rc -ne 0 ]; then
    echo "  $key FAILED (rc=$rc)" >&2
    record "$TAG" "$key" "failed"
    return $rc
  fi
  printf '  %-12s %8s ms\n' "$key" "$ms"
  record "$TAG" "$key" "$ms"
}

echo "=== $TAG"

# From nothing, every time: a start number measured against a builder that was
# already half up is not a start number.
builder_down "$STACK"
sleep 2
before_mem="$(builder_mem_mib "$STACK")"

phase start builder_up "$STACK" || exit 1

# Let the daemon settle before reading what it costs, and before timing
# anything against it.
sleep "${SETTLE:-10}"
after_mem="$(builder_mem_mib "$STACK")"
idle="$(delta "$after_mem" "$before_mem")"
printf '  %-12s %8s MiB  (%s -> %s, %s)\n' idle-mem "$idle" "$before_mem" "$after_mem" \
  "$([ "$STACK" = ferry ] && echo 'host phys_footprint' || echo 'in-guest used')"
record "$TAG" idle-mem "$idle"
record "$TAG" idle-mem-basis "$([ "$STACK" = ferry ] && echo host || echo guest)"

cache_prune "$STACK"

phase cold-build  do_build "$STACK" "$ctx" "$WORKLOAD" cacheonly
phase cold-export do_build "$STACK" "$ctx" "$WORKLOAD" "$tar"
phase cold-load   do_load "$tar"

record "$TAG" tar-bytes "$(stat -f %z "$tar" 2>/dev/null || echo 0)"

# The edit-rebuild loop.
date +%s > "$ctx/$EDIT"
phase incr-build  do_build "$STACK" "$ctx" "$WORKLOAD" cacheonly
phase incr-export do_build "$STACK" "$ctx" "$WORKLOAD" "$tar"
phase incr-load   do_load "$tar"

phase noop        do_build "$STACK" "$ctx" "$WORKLOAD" cacheonly

echo
