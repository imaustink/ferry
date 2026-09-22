#!/usr/bin/env bash
# One stack's idle memory, read every way at once.
#
# The report's idle row puts ferry's host-side phys_footprint next to kind's
# in-guest `used` and prints them as one column. summarize.py:52 is explicit
# about it -- mem_at() returns vm_footprint+host_footprint for ferry* and
# guest_used_mib for everything else -- and the docstring defends it, because
# the memory genuinely does not live in the same place. But a reader sees 1485
# against 695 and concludes ferry costs twice what kind costs, and on either
# basis measured consistently it does not.
#
# Two bases, and the in-guest one has two definitions that the harness already
# mixes: lib.sh:183 takes `free -m` column 3 (used), m2mem.sh takes $2-$7
# (total - available, which counts unreclaimable cache). Those disagree, so
# both are recorded rather than one being picked here.
#
#   ./crossmem.sh kind
#   ./crossmem.sh minikube
#   MEM=2Gi ./crossmem.sh ferry2
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/stacks.sh"

STACK="${1:?usage: crossmem.sh <kind|minikube|ferry2>}"
SETTLE="${SETTLE:-60}"
MEM="${MEM:-$MACHINE_MEM}"
DURABILITY="${DURABILITY:-}"          # empty = ferry's default (full)
RESTART_DOCKER="${RESTART_DOCKER:-1}" # 0 to skip, when Docker was just restarted
case "$STACK" in
  ferry2) TAG="cross-$STACK-$MEM${DURABILITY:+-$DURABILITY}" ;;
  *)      TAG="cross-$STACK" ;;
esac

FERRY_STATE="$("$FERRY" profile 2>/dev/null | awk '/^  state /{print $2}')"
FERRY_RUN="${FERRY_RUN:-$("$FERRY" profile 2>/dev/null | awk '/^  runtime /{print $2}')}"
export FERRY_RUN

say() { printf '\n== %s\n' "$*"; }

# Host phys_footprint attributable to this stack: its VM processes plus its
# own host-side daemons. For kind and minikube that is Docker Desktop's VM and
# Docker's backend processes; for ferry it is the pod/node VMs and the native
# control plane.
host_side() { # -> "vm host"
  local vm host
  case "$STACK" in
    ferry2) vm=$(footprint_mib $(ferry_vm_pids | tr '\n' ' '))
            host=$(footprint_mib $(ferry_host_pids | tr '\n' ' ')) ;;
    *)      vm=$(footprint_mib "$(docker_vm_pid)")
            host=$(footprint_mib $(docker_host_pids | tr '\n' ' ')) ;;
  esac
  echo "${vm:-0} ${host:-0}"
}

# Inside the guest, both definitions, from one reading so they cannot drift.
#
# For kind/minikube the guest is Docker Desktop's VM, reached with a plain
# `docker run`. For ferry the guest is the node VM, reached with a pod pinned
# to it -- and that pod is the only thing that can see it, since the Mac's own
# kubelet is not in that kernel.
guest_mem() { # -> "used total_minus_avail"
  local line
  case "$STACK" in
    ferry2) line=$(KUBECONFIG="$kc" kubectl run xmem-$RANDOM --rm -i --restart=Never \
              --image="$POD_IMAGE" \
              --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"worker-0"}}}' \
              -- free -m 2>/dev/null | awk '/^Mem:/{print $3, $2-$7}') ;;
    *)      line=$(docker run --rm "$POD_IMAGE" free -m 2>/dev/null \
              | awk '/^Mem:/{print $3, $2-$7}') ;;
  esac
  echo "${line:-0 0}"
}

report() { # phase
  local phase="$1" vm host used tma
  read -r vm host <<<"$(host_side)"
  read -r used tma <<<"$(guest_mem)"
  record "$TAG" "$phase.vm_footprint" "$vm"
  record "$TAG" "$phase.host_footprint" "$host"
  record "$TAG" "$phase.guest_used" "$used"
  record "$TAG" "$phase.guest_total_minus_avail" "$tma"
  record "$TAG" "$phase.vm_count" "$(vm_pids | wc -l | tr -d ' ')"
  printf '  %-9s host-side %8.1f (vm %.1f + native %.1f)   in-guest used %s / t-a %s\n' \
    "$phase" "$(python3 -c "print($vm+$host)")" "$vm" "$host" "$used" "$tma"
}

POD_IMAGE="${POD_IMAGE:-alpine:3.20}"
kc=""

case "$STACK" in
  kind|minikube)
    # Pinned before anything starts and re-checked after, because the pid this
    # resolves to is the whole measurement. stacks.sh records that "the first
    # VM in the process table" silently charged another VM's memory to kind
    # once already.
    #
    # The restart comes before the "is Docker up" check rather than after it,
    # because it is also what brings Docker up -- the ferry runs stop Docker on
    # purpose, so a minikube run following one would otherwise refuse to start
    # on a daemon it was about to launch itself.
    # Docker's VM keeps every page it has touched until Docker restarts, so a
    # baseline taken behind another Docker stack is that stack's leftovers and
    # the subtraction finds nothing. This is what made minikube's published
    # host-side row a 10 MiB non-result; see docker_restart in stacks.sh.
    [ "$RESTART_DOCKER" = "1" ] && { echo "restarting Docker for a clean baseline"; docker_restart || exit 1; }
    docker info >/dev/null 2>&1 || { echo "docker is not running"; exit 1; }
    pin_docker_vm
    d0=$(docker_vm_pid)
    [ -n "$d0" ] || { echo "could not find Docker Desktop's VM process"; exit 1; }
    echo "docker VM pinned to pid $d0"
    say "baseline (docker up, no cluster)"
    report baseline
    say "bringing $STACK up"
    stack_up "$STACK"
    kc=$(kubeconfig_of "$STACK"); ctx=$(context_of "$STACK")
    wait_ready "$kc" "$ctx" 600 || { echo "never became ready"; tail -20 "$RESULTS/$STACK-up.log"; }
    ;;
  ferry2)
    "$FERRY" down --purge >/dev/null 2>&1; sleep 5
    say "baseline (nothing running)"
    report baseline
    say "bringing mode 2 up with a $MEM node"
    seq_file="$BENCH_HOME/.machine-subnet-seq"
    n=$(( $(cat "$seq_file" 2>/dev/null || echo 29) + 1 )); echo "$n" > "$seq_file"
    export FERRY_MACHINE_SUBNET="192.168.$n.0/24"
    if [ -n "$DURABILITY" ]; then
      "$FERRY" up --durability "$DURABILITY" >"$RESULTS/$TAG-up.log" 2>&1
    else
      "$FERRY" up >"$RESULTS/$TAG-up.log" 2>&1
    fi
    for _ in $(seq 1 12); do
      echo "$n" > "$seq_file"
      FERRY_MACHINE_SUBNET="192.168.$n.0/24" "$FERRY" machines enable >>"$RESULTS/$TAG-up.log" 2>&1
      pgrep -f 'bin/ferry-machined' >/dev/null 2>&1 && break
      n=$((n + 1)); sleep 2
    done
    kc=$("$FERRY" kubeconfig)
    KUBECONFIG="$kc" kubectl apply -f - >>"$RESULTS/$TAG-up.log" 2>&1 <<YAML
apiVersion: ferry.dev/v1alpha1
kind: Machine
metadata: {name: worker-0}
spec: {cpus: $MACHINE_CPUS, memory: $MEM}
YAML
    # The node object has to exist before it can be waited on: `kubectl wait`
    # on a missing object fails immediately with "not found" rather than
    # waiting for it to appear, and ferry-machined creates the Machine's node
    # only once the VM has booted and its kubelet has registered. So this waits
    # for existence first and readiness second -- the same two-step
    # m2-size-sweep.sh does, which is why that one never reported a false miss.
    for _ in $(seq 1 400); do
      KUBECONFIG="$kc" kubectl get node worker-0 >/dev/null 2>&1 && break
      sleep 1
    done
    KUBECONFIG="$kc" kubectl wait --for=condition=Ready node/worker-0 --timeout=400s >/dev/null 2>&1 \
      || { echo "worker-0 never went Ready"; tail -5 "$RESULTS/$TAG-up.log"; }
    ;;
  *) echo "unknown stack $STACK"; exit 2 ;;
esac

say "settling ${SETTLE}s"
sleep "$SETTLE"

case "$STACK" in
  kind|minikube)
    d1=$(docker_vm_pid)
    [ "$d0" = "$d1" ] || echo "  WARNING: docker VM pid moved $d0 -> $d1; the delta is not a delta"
    ;;
esac

report idle

say "tearing down"
case "$STACK" in
  ferry2) "$FERRY" down --purge >/dev/null 2>&1 ;;
  *)      stack_down "$STACK" ;;
esac
echo "rows under tag $TAG in $RESULTS/raw.tsv"
