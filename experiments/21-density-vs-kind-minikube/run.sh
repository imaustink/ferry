#!/usr/bin/env bash
# ferry against kind and minikube, on one Mac, measured the same way.
#
# The README makes two claims -- nothing to size up front, and nothing to wait
# for -- and both are comparative. This measures them against the two tools
# people actually reach for, plus ferry's own second mode, so the comparison is
# a number rather than an argument.
#
#   ./experiments/21-density-vs-kind-minikube/run.sh [--pods 8]
#
# What is measured, per stack:
#
#   up          nothing to a cluster that answers kubectl
#   first pod   a pod reaching Running, image already pulled
#   memory      host memory the stack costs, at rest and per pod
#   down        tearing it down again
#
# Memory is read from vm_stat rather than from process lists, and that is the
# decision that makes this fair. ferry spreads its cost over a control plane,
# a runtime and one VM per pod; kind and minikube put theirs inside Docker
# Desktop's VM, where a per-process RSS on the Mac shows almost nothing. Asking
# the kernel what the whole machine is using, before and after, is the only
# measure that means the same thing for all four.
#
# What it cannot control for, and says so in the output: Docker Desktop's VM is
# sized up front, so kind and minikube start with memory already committed that
# does not appear in their delta. That is not noise to be removed -- it is the
# thing the README is about -- so it is reported separately rather than folded
# in.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"

PODS="${PODS:-8}"
# Re-measure one stack without redoing the others, appending to what is there.
ONLY="${ONLY:-}"
# Small, and the same everywhere. Pulled once per stack before the clock starts,
# because a registry round trip measures the network rather than the stack.
IMAGE="${IMAGE:-public.ecr.aws/docker/library/alpine:3.20}"
# Names of our own, so nothing here touches a cluster somebody else is using.
BENCH="ferrybench"
FERRY_BENCH_PROFILE="bench"

while [ $# -gt 0 ]; do
  case "$1" in
    --pods) PODS="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    *) echo "usage: run.sh [--pods N] [--image REF]" >&2; exit 2 ;;
  esac
done

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
say()  { printf '    %s\n' "$1"; }
row()  { printf '%-12s %-14s %s\n' "$1" "$2" "$3"; }

# --- measurement ----------------------------------------------------------

# Host memory in use, MiB. active + wired + compressed: the pages the machine
# cannot hand to anyone else. Inactive is excluded because macOS counts cache
# there and it is reclaimable, which would read as cost that is not cost.
used_mib() {
  vm_stat | awk -v page="$(sysctl -n hw.pagesize)" '
    /Pages active/      {gsub(/\./,"",$3); a=$3}
    /Pages wired down/  {gsub(/\./,"",$4); w=$4}
    /Pages occupied by compressor/ {gsub(/\./,"",$5); c=$5}
    END {printf "%.0f", (a + w + c) * page / 1048576}'
}

# Memory used inside a node container, MiB. MemTotal - MemAvailable, read from
# the guest's own /proc.
#
# This exists because the host cannot answer the question for kind or minikube.
# Their pods live inside Docker Desktop's VM, whose memory is committed when the
# VM starts: allocating a gigabyte inside it moves no host process's RSS by a
# single page, and a vm_stat delta around it returns noise -- the first run of
# this reported kind costing *minus* 210 MiB for a cluster and a pod.
#
# That is not a measurement failure to work around, it is the difference being
# measured. A pod on kind costs the Mac nothing extra because the memory was
# already taken; it costs a slice of the fixed VM you sized before you started,
# and when that is gone, pods stop fitting. So the honest comparison is two
# numbers that mean different things, labelled as such: what a pod takes from
# the VM you committed, against what a pod takes from the Mac.
guest_used_mib() { # container
  docker exec "$1" sh -c 'awk "/MemTotal/{t=\$2} /MemAvailable/{a=\$2} END{printf \"%.0f\", (t-a)/1024}" /proc/meminfo' 2>/dev/null || echo 0
}

# Memory settles for a while after a cluster starts -- pages get faulted in,
# caches fill. Measuring immediately reports less than the steady state.
settle() { sleep "${1:-20}"; }

now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
since()  { echo "scale=1; ($(now_ms) - $1) / 1000" | bc; }

# --- results --------------------------------------------------------------

RESULTS="$here/results.tsv"
[ -n "$ONLY" ] || : > "$RESULTS"
record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$RESULTS"; }


# --- the workload --------------------------------------------------------
#
# One pod spec, one way of creating it, for all four stacks. kind and minikube
# used `kubectl run` here and ferry used a manifest, which is a difference
# between the things being compared that has nothing to do with what is being
# measured.
#
# Every kubectl call names its --context explicitly rather than relying on the
# current one. Two reasons: a benchmark should not depend on, or quietly
# rewrite, whichever cluster the operator happens to be pointed at; and
# `kubectl config use-context` failing is silent, which is exactly how the
# first two runs of this produced "pod never became Ready" against a cluster
# that was perfectly healthy.
pod_manifest() { # name shared|any
  printf 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: %s\nspec:\n' "$1"
  [ "${2:-any}" = shared ] && printf '  nodeSelector: {ferry.dev/mode: shared}\n'
  printf '  restartPolicy: Never\n  containers:\n    - name: c\n      image: %s\n      command: ["sleep", "3600"]\n' "$IMAGE"
}

# A cluster that answers kubectl is not yet a cluster that can run a pod. The
# API server accepts a connection well before kube-controller-manager has
# created the default ServiceAccount, and a pod created in that window is
# rejected outright:
#
#   pods "p0" is forbidden: error looking up service account default/default
#
# kind returns from `create cluster` inside that window. So "up" is measured to
# here rather than to the create command returning -- for every stack, so the
# number means the same thing -- because being able to run a pod is what anyone
# means by the cluster being up.
wait_ready_for_pods() { # context
  local ctx="$1" as=() waited=0
  [ -n "$ctx" ] && as=(--context "$ctx")
  while [ "$waited" -lt 180 ]; do
    kubectl ${as[@]+"${as[@]}"} get serviceaccount default -n default >/dev/null 2>&1 && return 0
    sleep 1; waited=$((waited + 1))
  done
  say "the default ServiceAccount never appeared"
  return 1
}

# Create a pod and wait for it, returning non-zero with the reason rather than
# recording a meaningless number.
start_pod() { # context name shared|any timeout
  local ctx="$1" name="$2" placement="${3:-any}" timeout="${4:-300s}"
  # An empty context means "whatever KUBECONFIG points at", which is how ferry
  # is addressed: it keeps its own kubeconfig file rather than an entry in the
  # operator's.
  local as=()
  [ -n "$ctx" ] && as=(--context "$ctx")
  if ! pod_manifest "$name" "$placement" | kubectl ${as[@]+"${as[@]}"} apply -f - >/dev/null 2>&1; then
    say "could not create $name"
    pod_manifest "$name" "$placement" | kubectl ${as[@]+"${as[@]}"} apply -f - 2>&1 | tail -2 | sed 's/^/        /'
    return 1
  fi
  if ! kubectl ${as[@]+"${as[@]}"} wait --for=condition=Ready "pod/$name" --timeout="$timeout" >/dev/null 2>&1; then
    say "$name never became Ready"
    kubectl ${as[@]+"${as[@]}"} get "pod/$name" 2>&1 | tail -1 | sed 's/^/        /'
    return 1
  fi
}

# --- the stacks -----------------------------------------------------------

bench_kind() {
  bold "kind"
  kind delete cluster --name "$BENCH" >/dev/null 2>&1
  settle 5
  local base; base="$(used_mib)"

  local t0; t0="$(now_ms)"
  kind create cluster --name "$BENCH" >/dev/null 2>&1 || { say "create failed"; return 1; }
  wait_ready_for_pods "kind-$BENCH" || return 1
  local up; up="$(since "$t0")"
  record kind up "$up"; say "up: ${up}s"

  local ctx="kind-$BENCH"
  # Pulled into the node before the clock starts, so the pod timing is the
  # stack's scheduling and start path rather than a registry fetch.
  docker exec "$BENCH-control-plane" crictl pull "$IMAGE" >/dev/null 2>&1

  t0="$(now_ms)"
  start_pod "$ctx" p0 any 180s || return 1
  local pod; pod="$(since "$t0")"
  record kind first_pod "$pod"; say "first pod: ${pod}s"

  settle
  local one; one="$(guest_used_mib "$BENCH-control-plane")"
  record kind guest_mem_1pod "$one"; say "in-VM memory, cluster + 1 pod: ${one} MiB"

  local i; for i in $(seq 1 $((PODS - 1))); do
    pod_manifest "p$i" any | kubectl --context "$ctx" apply -f - >/dev/null 2>&1
  done
  kubectl --context "$ctx" wait --for=condition=Ready pod --all --timeout=300s >/dev/null 2>&1
  settle
  local many; many="$(guest_used_mib "$BENCH-control-plane")"
  record kind "guest_mem_${PODS}pods" "$many"
  record kind guest_marginal "$(echo "scale=1; ($many - $one) / ($PODS - 1)" | bc)"
  say "in-VM memory, cluster + $PODS pods: ${many} MiB"

  t0="$(now_ms)"
  kind delete cluster --name "$BENCH" >/dev/null 2>&1
  record kind down "$(since "$t0")"
  settle 5
}

bench_minikube() {
  bold "minikube"
  minikube delete -p "$BENCH" >/dev/null 2>&1
  settle 5
  local base; base="$(used_mib)"

  local t0; t0="$(now_ms)"
  minikube start -p "$BENCH" >/dev/null 2>&1 || { say "start failed"; return 1; }
  wait_ready_for_pods "$BENCH" || return 1
  local up; up="$(since "$t0")"
  record minikube up "$up"; say "up: ${up}s"

  local ctx="$BENCH"
  minikube -p "$BENCH" image pull "$IMAGE" >/dev/null 2>&1

  t0="$(now_ms)"
  start_pod "$ctx" p0 any 180s || return 1
  local pod; pod="$(since "$t0")"
  record minikube first_pod "$pod"; say "first pod: ${pod}s"

  settle
  local one; one="$(guest_used_mib "$BENCH")"
  record minikube guest_mem_1pod "$one"; say "in-VM memory, cluster + 1 pod: ${one} MiB"

  local i; for i in $(seq 1 $((PODS - 1))); do
    pod_manifest "p$i" any | kubectl --context "$ctx" apply -f - >/dev/null 2>&1
  done
  kubectl --context "$ctx" wait --for=condition=Ready pod --all --timeout=300s >/dev/null 2>&1
  settle
  local many; many="$(guest_used_mib "$BENCH")"
  record minikube "guest_mem_${PODS}pods" "$many"
  record minikube guest_marginal "$(echo "scale=1; ($many - $one) / ($PODS - 1)" | bc)"
  say "in-VM memory, cluster + $PODS pods: ${many} MiB"

  t0="$(now_ms)"
  minikube delete -p "$BENCH" >/dev/null 2>&1
  record minikube down "$(since "$t0")"
  settle 5
}

# ferry, in whichever mode. Mode 2 needs a Machine to exist before a pod can
# land on one, and creating it is part of what mode 2 costs, so it is inside
# the clock for "up" rather than outside it.
bench_ferry() { # mode1|mode2
  local mode="$1"
  bold "ferry $mode"
  export FERRY_PROFILE="$FERRY_BENCH_PROFILE"
  export KUBECONFIG="$HOME/.ferry-$FERRY_BENCH_PROFILE/admin.conf"

  "$root/ferry" down --purge >/dev/null 2>&1
  # vmnet keeps a subnet for about a minute after the process using it stops,
  # and a benchmark that starts inside that window measures the fallback path.
  sleep 75
  local base; base="$(used_mib)"

  local t0; t0="$(now_ms)"
  FERRY_ALLOW_OFF_SLICE=1 "$root/ferry" up >/dev/null 2>&1 || { say "up failed"; return 1; }
  if [ "$mode" = mode2 ]; then
    "$root/ferry" machines on >/dev/null 2>&1 || { say "machines failed"; return 1; }
    kubectl apply -f - >/dev/null 2>&1 <<EOF
apiVersion: ferry.dev/v1alpha1
kind: Machine
metadata: {name: bench}
spec: {cpus: 4, memory: 4Gi}
EOF
    local waited=0
    while [ "$waited" -lt 300 ]; do
      kubectl get nodes 2>/dev/null | grep -qE "bench +Ready" && break
      sleep 5; waited=$((waited + 5))
    done
  fi
  wait_ready_for_pods "" || return 1
  local up; up="$(since "$t0")"
  record "ferry-$mode" up "$up"; say "up: ${up}s"

  local placement=any
  [ "$mode" = mode2 ] && placement=shared

  # Warm the image the same way the others are warmed.
  start_pod "" warm "$placement" 300s || return 1
  kubectl delete pod warm --wait=true --timeout=120s >/dev/null 2>&1

  t0="$(now_ms)"
  start_pod "" p0 "$placement" 300s || return 1
  local pod; pod="$(since "$t0")"
  record "ferry-$mode" first_pod "$pod"; say "first pod: ${pod}s"

  settle
  local one; one="$(( $(used_mib) - base ))"
  record "ferry-$mode" host_mem_1pod "$one"; say "host memory, cluster + 1 pod: ${one} MiB"

  local i; for i in $(seq 1 $((PODS - 1))); do
    pod_manifest "p$i" "$placement" | kubectl apply -f - >/dev/null 2>&1
  done
  kubectl wait --for=condition=Ready pod --all --timeout=600s >/dev/null 2>&1
  settle
  local many; many="$(( $(used_mib) - base ))"
  record "ferry-$mode" "host_mem_${PODS}pods" "$many"
  record "ferry-$mode" host_marginal "$(echo "scale=1; ($many - $one) / ($PODS - 1)" | bc)"
  say "host memory, cluster + $PODS pods: ${many} MiB"

  t0="$(now_ms)"
  "$root/ferry" down --purge >/dev/null 2>&1
  record "ferry-$mode" down "$(since "$t0")"
  unset FERRY_PROFILE KUBECONFIG
}

# --- what is fixed before anything starts ---------------------------------

bold "the machine"
say "$(sysctl -n hw.model), $(sysctl -n hw.memsize | awk '{printf "%.0f GiB", $1/1073741824}'), macOS $(sw_vers -productVersion)"
if docker info >/dev/null 2>&1; then
  dm="$(docker info --format '{{.MemTotal}}' | awk '{printf "%.1f", $1/1073741824}')"
  dc="$(docker info --format '{{.NCPU}}')"
  say "Docker Desktop VM: ${dm} GiB and ${dc} cpus, allocated before any cluster exists"
  record docker vm_gib "$dm"
  record docker vm_cpus "$dc"
fi
say "ferry allocates nothing up front; a pod VM is created when a pod is"
echo

bold "running $PODS pods per stack, image $IMAGE"
echo

case "$ONLY" in
  ""|kind)     bench_kind; echo ;;
esac
case "$ONLY" in
  ""|minikube) bench_minikube; echo ;;
esac
case "$ONLY" in
  ""|ferry|ferry-mode1) bench_ferry mode1; echo ;;
esac
case "$ONLY" in
  ""|ferry|ferry-mode2) bench_ferry mode2; echo ;;
esac

bold "results"
column -t -s "$(printf '\t')" "$RESULTS"
echo
say "written to $RESULTS"
