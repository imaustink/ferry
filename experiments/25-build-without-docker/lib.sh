#!/usr/bin/env bash
# Three substrates, one builder.
#
# The temptation was to drive each stack the way its own users would -- `ferry
# image build` against a pod, `docker buildx build` against Docker Desktop,
# `nerdctl build` against colima -- and that would have measured three
# different buildkit configurations as much as three substrates. buildx's
# default driver does not even accept `--output type=cacheonly`, so the cell
# that separates build time from export time could not have been run on it.
#
# So every stack here runs the *same* daemon -- moby/buildkit v0.29.0, the same
# flags -- and the same client, the buildctl already on the Mac. The only thing
# that differs is what the daemon is running inside:
#
#   ferry    a pod, which is a virtual machine of its own (Containerization)
#   docker   a container in Docker Desktop's VM
#   colima   a container in colima's lima VM
#
# and therefore what the address is. Everything else is held still.
#
# The handoff is held still too: every stack exports `type=oci` and hands the
# tarball to `ferry image load`, so the image ends up in the same store by the
# same path and the export is charged to all three alike.

BENCH_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS="${RESULTS:-$BENCH_HOME/results}"
FERRY="${FERRY:-$(cd "$BENCH_HOME/../.." && pwd)/ferry}"
mkdir -p "$RESULTS"

# footprint_mib, used_mib, ferry_vm_pids, docker_vm_pid and friends already
# exist and have been argued over at length; see experiment 24 and
# docs/BENCHMARKING.md. RESULTS is set above so sourcing this does not write
# into that experiment's results.
#
# It sets BENCH_HOME and FOOTPRINT_MISSED_FILE to its own, so both are put
# back afterwards -- otherwise every path below resolves into experiment 24.
# shellcheck source=../24-benchmark-harness/lib.sh
source "$BENCH_HOME/../24-benchmark-harness/lib.sh"
BENCH_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS="${RESULTS:-$BENCH_HOME/results}"
FOOTPRINT_MISSED_FILE="$BENCH_HOME/.footprint-missed"
mkdir -p "$RESULTS"

BUILDKIT_IMAGE="${BUILDKIT_IMAGE:-moby/buildkit:v0.29.0}"
FERRY_KUBECONFIG="$("$FERRY" kubeconfig 2>/dev/null)"
SCRATCH="${SCRATCH:-${TMPDIR:-/tmp}/ferry-build-bench}"
mkdir -p "$SCRATCH"

kc() { KUBECONFIG="$FERRY_KUBECONFIG" kubectl "$@"; }

# Where each stack's daemon answers.
#
# ferry's is the pod's real address on the vmnet subnet the Mac is already on
# (docs/POD-NETWORK.md), so nothing is forwarded and nothing translates. The
# other two are published ports on loopback, which is the only way into their
# VMs and is worth remembering when reading the transfer numbers.
addr_of() { # stack -> host:port
  case "$1" in
    ferry)  echo "$(kc get pod buildkitd -o jsonpath='{.status.podIP}'):1234" ;;
    docker) echo "127.0.0.1:1234" ;;
    colima) echo "127.0.0.1:1235" ;;
    *) echo "addr_of: unknown stack $1" >&2; return 1 ;;
  esac
}

# Docker CLI aimed at the right daemon.
#
# Both contexts are named explicitly and neither is left to the default,
# because `colima start` *switches the current context to colima* -- so a bare
# `docker build` after starting colima silently measures colima while claiming
# to measure Docker Desktop. That is a one-line mistake that produces entirely
# plausible numbers.
DOCKER_CTX="${DOCKER_CTX:-desktop-linux}"
COLIMA_CTX="${COLIMA_CTX:-colima}"
dk() { # stack args...
  local stack="$1"; shift
  case "$stack" in
    docker) docker --context "$DOCKER_CTX" "$@" ;;
    colima) docker --context "$COLIMA_CTX" "$@" ;;
  esac
}

builder_ready() { # stack
  local a; a="$(addr_of "$1" 2>/dev/null)" || return 1
  [ -n "${a%%:*}" ] || return 1
  buildctl --addr "tcp://$a" debug workers >/dev/null 2>&1
}

# From nothing to a daemon that answers. Timed by the caller: this is the cost
# a per-build builder would pay every time, and the cost a warm one pays once.
builder_up() { # stack
  local stack="$1"
  case "$stack" in
    ferry)
      kc apply -f "$BENCH_HOME/manifests/${BUILDER_MANIFEST:-buildkitd.yaml}" >/dev/null ;;
    docker|colima)
      local port=1234; [ "$stack" = colima ] && port=1235
      dk "$stack" rm -f buildkitd >/dev/null 2>&1
      dk "$stack" run -d --name buildkitd --privileged \
        -p "$port:1234" "$BUILDKIT_IMAGE" \
        --addr tcp://0.0.0.0:1234 >/dev/null ;;
  esac
  ferry_await_ready "$stack" 180
}

# Poll finely. A ferry pod is up in a fraction of a second and a poll at
# half-second ticks would charge it for the ticks.
ferry_await_ready() { # stack timeout_s
  local stack="$1" limit="${2:-180}" i=0 ticks=$(( ${2:-180} * 20 ))
  while [ "$i" -lt "$ticks" ]; do
    builder_ready "$stack" && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

builder_down() { # stack
  case "$1" in
    ferry)  kc delete pod buildkitd --ignore-not-found --wait=true >/dev/null 2>&1 ;;
    docker|colima) dk "$1" rm -f buildkitd >/dev/null 2>&1 ;;
  esac
}

cache_prune() { # stack
  local a; a="$(addr_of "$1")"
  buildctl --addr "tcp://$a" prune --all >/dev/null 2>&1
}

# One build. `cacheonly` leaves the result in the builder and exports nothing,
# which is the only way to price the build without the export riding along;
# `oci` writes the tarball the handoff then loads.
#
# The context is a copy under $SCRATCH rather than the checkout: the
# incremental cell edits a source file, and a benchmark that dirties the
# working tree it is run from is a benchmark someone will run once.
do_build() { # stack context-dir name out(cacheonly|<tarball path>)
  local stack="$1" ctx="$2" workload="$3" out="$4" a
  a="$(addr_of "$stack")"
  # No --output at all is buildctl's "build it and keep the result here".
  # `type=cacheonly` is buildx vocabulary and buildctl rejects it outright --
  # "exporter cacheonly could not be found" -- so the flag is dropped rather
  # than set to anything.
  local args=(build --frontend dockerfile.v0 --local "context=$ctx" --local "dockerfile=$ctx")
  [ "$out" = cacheonly ] || args+=(--output "type=oci,name=bench-$workload:dev,dest=$out")
  buildctl --addr "tcp://$a" "${args[@]}" >/dev/null 2>&1
}

# The other half of the loop, identical for all three stacks.
do_load() { # tarball
  "$FERRY" image load "$1" >/dev/null 2>&1
}

# What the builder costs while it sits there.
#
# The two bases do not mix -- docs/BENCHMARKING.md's one rule. ferry's builder
# is a macOS VM process small enough for vmmap to resolve, so it is read
# host-side; docker's and colima's live inside a VM whose phys_footprint is
# pinned to its allocation and will not move, so they are read from inside
# that VM. Both are taken as a delta across starting the builder, which is the
# only way to attribute anything inside a shared guest to it.
ferry_vm_footprint() {
  footprint_mib $(ferry_vm_pids | tr '\n' ' ')
}

guest_used_mib() { # stack
  dk "$1" run --rm alpine:3.20 free -m 2>/dev/null | awk '/^Mem:/ {print $3}'
}

# The number that belongs in the builder's column, whichever basis it is on.
builder_mem_mib() { # stack
  case "$1" in
    ferry)  ferry_vm_footprint ;;
    docker|colima) guest_used_mib "$1" ;;
  esac
}

delta() { python3 -c "import sys;print(f'{float(sys.argv[1])-float(sys.argv[2]):.1f}')" "$1" "$2"; }
ms_since() { echo $(( $(now_ms) - $1 )); }
