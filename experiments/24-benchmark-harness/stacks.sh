#!/usr/bin/env bash
# One interface per stack: up, down, where its kubeconfig is, and which host
# processes belong to it. Each cluster is created under a name of its own and
# writes its own kubeconfig, so nothing here touches an existing cluster or
# ~/.kube/config.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KC_DIR="$BENCH_HOME/kubeconfigs"; mkdir -p "$KC_DIR"
# Overridable because a kind cluster can outlive the ability to delete it. A
# node container killed by the OOM reaper left a record `docker ps -a` lists
# and `docker inspect` and `docker rm` both deny exists, surviving a Docker
# Desktop restart -- so `kind create` refused the name and `kind delete` could
# not clear it. Purging Docker's data would fix it and take every other
# container on the machine with it; a different name costs nothing.
CLUSTER="${CLUSTER:-bench}"

# Docker Desktop's VM. Its parent is launchd, not Docker, so parentage is no
# help; it is identified by the disk image it has open.
#
# It used to be "the first VM in the process table", on the reasoning that it
# was the only one there before ferry started. That is true on an idle laptop
# and false on this one -- a Claude sandbox VM and three orphaned ferry pod
# VMs from other profiles were all ahead of it -- and picking the wrong one
# puts an unrelated VM's memory in kind's column and leaves Docker's out.
DOCKER_VM_PID_FILE="$BENCH_HOME/.docker-vm-pid"
docker_vm_pid() { cat "$DOCKER_VM_PID_FILE" 2>/dev/null; }
# Docker Desktop, stopped and started again, so the next stack's baseline is a
# baseline.
#
# Its VM never gives pages back. Deleting a kind cluster leaves the VM process
# exactly where that cluster left it -- measured: 3891.2 MiB before the delete
# and 3891.2 MiB after -- so the stack measured next inherits those pages as
# its "baseline" and its own cluster then fits inside memory the host has
# already been charged for. That is the whole of minikube's 4403.2 -> 4403.2
# idle row: it ran second, behind kind, and the subtraction had nothing left to
# find. kind's own number is sound only because it ran first.
#
# Restarting is the only thing that returns the pages, which is the same fact
# experiment 14 records inside ferry's guests, one level out. ferry needs no
# equivalent: its VMs exit with the cluster, so its baseline is a real zero.
docker_restart() {
  osascript -e 'quit app "Docker Desktop"' >/dev/null 2>&1
  local n=0
  while pgrep -f 'Docker.app/Contents/MacOS/com.docker.backend' >/dev/null 2>&1; do
    sleep 2; n=$((n + 1)); [ "$n" -gt 60 ] && break
  done
  sleep 3
  open -a "Docker Desktop" >/dev/null 2>&1 || open -a Docker >/dev/null 2>&1
  n=0
  until docker info >/dev/null 2>&1; do
    sleep 3; n=$((n + 1)); [ "$n" -gt 100 ] && { echo "docker did not come back" >&2; return 1; }
  done
  # Settle: the VM keeps touching pages for a while after the socket answers,
  # and a baseline taken into that climb reads low.
  sleep 20
}

pin_docker_vm() {
  local pid
  : > "$DOCKER_VM_PID_FILE"
  for pid in $(vm_pids); do
    if lsof -p "$pid" 2>/dev/null | grep -qF "com.docker.docker/Data/vms"; then
      echo "$pid" > "$DOCKER_VM_PID_FILE"; return
    fi
  done
}

# Mode 2's node is sized the way ferry ships it, which is what a user actually
# gets: ferry-machined defaults spec.memory to 2Gi (crd.yaml).
#
# It was 15Gi, to mirror Docker Desktop's VM, on the reasoning that "guest
# memory is lazily backed, so a ceiling it does not touch costs nothing
# (experiment 14)". That is true of the guest's pages and false of the guest's
# kernel. Apple's config is CONFIG_ARM64_4K_PAGES with SPARSEMEM_VMEMMAP, so a
# struct page is allocated for every 4 KiB of the *ceiling* at boot, and
# several hash tables are sized from total RAM besides. Those pages are
# touched, and experiment 14's own finding is that touched pages never come
# back. Measured standalone, guest touching nothing: 112 / 136 / 240 / 325 /
# 469 MiB resident at 1 / 2 / 4 / 8 / 15 GiB configured -- about 105 MiB fixed
# plus 2.5% of the ceiling.
#
# End to end that was 356 MiB of mode 2's idle row spent on memory no pod can
# use (1,538 MiB at 15Gi against 1,182 at 2Gi), and it bought nothing: the
# 20-pod burst is 1.22-1.26 s across the whole range, medians of three, with
# per-run spread of 0.03 s. m2-size-sweep.sh is that measurement.
#
# Set MACHINE_MEM=15Gi for the Docker-matched comparison; it is a fair thing to
# want, it is just not what the product does.

# The CPU count still mirrors Docker Desktop, because cores are not memory:
# an unused core costs the host nothing, so matching them costs nothing and an
# unmatched burst measures the mismatch.
#
# It claimed to be matched and was not: the count was hardcoded to 10 while
# Docker Desktop on this machine had all 16, so every burst gave kind 60% more
# CPU than ferry. Asked directly rather than guessed now. (Measured before
# fixing it, for the record: ferry's 20-pod burst comes out the same at 10 and
# at 16, so this was never the concurrency gap -- but a comparison that claims
# to be matched should be matched.)
#
# Asked of Docker when it is running, and of the Mac when it is not -- the
# ferry runs stop Docker Desktop on purpose, and Docker Desktop takes every
# core by default, so the host's count is the same answer from the other side.
#
# Not `docker info ... || echo N`: with the daemon down, docker prints "0" on
# *stdout* and exits 1, so the substitution captured "0\n10" and the Machine
# manifest became `cpus: 0` followed by a bare `10` on its own line. Validated
# rather than trusted, for that reason.
machine_cpus_default() {
  local v
  v="$(docker info --format '{{.NCPU}}' 2>/dev/null | head -1)"
  case "$v" in ''|*[!0-9]*|0) ;; *) echo "$v"; return ;; esac
  v="$(sysctl -n hw.ncpu 2>/dev/null)"
  case "$v" in ''|*[!0-9]*|0) echo 10 ;; *) echo "$v" ;; esac
}
MACHINE_CPUS="${MACHINE_CPUS:-$(machine_cpus_default)}"
MACHINE_MEM="${MACHINE_MEM:-2Gi}"

# The Kubernetes the other stacks run, pinned to the one ferry is built at.
#
# kind defaults to whatever node image its own release was cut against, which
# is not ferry's default and drifts every time either side releases. Comparing
# a pod start across two different kubelet minors measures the minors as much
# as it measures the stacks, and nothing in the output said which it had --
# the versions matched by luck, when they matched at all. Reading it from
# lib/versions.sh means a ferry version bump moves kind with it, and a
# kindest/node tag that does not exist fails at cluster creation naming the
# tag, rather than quietly benchmarking a different minor.
K8S_VERSION="${K8S_VERSION:-$(
  sed -n 's/^FERRY_DEFAULT_K8S_VERSION="\(.*\)"/\1/p' \
    "$BENCH_HOME/../../lib/versions.sh")}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:$K8S_VERSION}"

# The kubelet's log level, for whichever stack is being brought up.
#
# One knob rather than two, because the comparison is worthless asymmetric:
# the volume manager and the pod workers only narrate themselves above v=3,
# so a ferry at v=4 against a kind at its default v=2 produces a detailed
# account of one stack and "no complete pod traces" for the other, which
# reads like a difference between them and is a difference in the logging.
#
# ferry reads it from the environment (ferry-node puts it on the guest's
# kernel command line); kind takes it through a kubeadm patch, which is why
# stack_up has to write a config file for it rather than pass a flag.
KUBELET_V="${KUBELET_V:-}"

kubeconfig_of() {
  case "$1" in
    ferry|ferry2) "$FERRY" kubeconfig 2>/dev/null ;;
    kind)     echo "$KC_DIR/kind.yaml" ;;
    minikube) echo "$KC_DIR/minikube.yaml" ;;
  esac
}
context_of() {
  case "$1" in
    ferry|ferry2) echo "" ;;
    kind)     echo "kind-$CLUSTER" ;;
    minikube) echo "$CLUSTER" ;;
  esac
}

# --- host processes the stack is responsible for -------------------------

# ferry: its native processes, plus every VM that is not Docker's.
# kind/minikube: Docker Desktop's VM, which is where the whole cluster lives.
stack_vm_pids() {
  local d; d=$(docker_vm_pid)
  case "$1" in
    # By what they have open, not by "not Docker's" -- see ferry_vm_pids.
    ferry|ferry2) ferry_vm_pids ;;
    *)     echo "$d" ;;
  esac
}
stack_host_pids() {
  case "$1" in
    ferry|ferry2) ferry_host_pids ;;
    *)     docker_host_pids ;;
  esac
}

# Which node the battery's pods have to land on.
#
# With mode 2 enabled the cluster has two nodes and they are not the same
# architecture: the Mac node runs a VM per pod, the machine node runs
# containers sharing one kernel. An unpinned Deployment is scheduled across
# both -- measured at an even 5/5 split of ten replicas -- so every ferry2
# latency and memory row becomes a mixture of the two modes rather than a
# measurement of either, and the mixture changes from run to run with whatever
# the scheduler scores.
#
# Mode 1 needs no selector: `ferry machines disable` leaves one node.
node_selector_of() {
  case "$1" in
    ferry2) printf '      nodeSelector: {ferry.dev/mode: shared}\n' ;;
    *)      : ;;
  esac
}

# --- lifecycle -----------------------------------------------------------

stack_up() {
  local s="$1" kc; kc=$(kubeconfig_of "$s")
  case "$s" in
    ferry)
      # Mode 1 means mode 1 only. With machines enabled `ferry up` also applies
      # kube-proxy and coredns-machines, which -- as ferry says when it does it
      # -- stay Pending until a machine exists to run them on. Leaving them
      # there measures mode 1 on a cluster that is half mode 2, and wedges the
      # readiness wait on pods that can never schedule.
      "$FERRY" machines disable >"$RESULTS/$s-up.log" 2>&1
      "$FERRY" up >>"$RESULTS/$s-up.log" 2>&1 ;;
    ferry2)
      # Mode 1 first -- mode 2 is a controller and a Machine on top of the same
      # control plane, not a separate cluster.
      # The subnet has to be chosen before `ferry up`, not just before
      # `machines enable`: with mode 2 on, `ferry up` brings the machine network
      # up itself, and it uses the default subnet unless told otherwise. After a
      # teardown that subnet is still held, so `up` stalls on it and the retry
      # below only fixes the half that comes after.
      seq_file="$BENCH_HOME/.machine-subnet-seq"
      n=$(( $(cat "$seq_file" 2>/dev/null || echo 29) + 1 ))
      echo "$n" > "$seq_file"
      export FERRY_MACHINE_SUBNET="192.168.$n.0/24"
      # Read by ferry-node when it builds the machine's kernel command line.
      [ -n "$KUBELET_V" ] && export FERRY_KUBELET_V="$KUBELET_V"
      "$FERRY" up >"$RESULTS/$s-up.log" 2>&1
      # vmnet holds a subnet after the process using it stops -- documented as
      # about a minute, observed far longer -- so an enable that follows a
      # teardown is refused. Waiting is unreliable; moving to a subnet this run
      # has not used is not. A counter file survives across the battery's own
      # create/delete cycles, which is the case that kept failing.
      for _ in $(seq 1 12); do
        echo "$n" > "$seq_file"
        FERRY_MACHINE_SUBNET="192.168.$n.0/24" \
          "$FERRY" machines enable >>"$RESULTS/$s-up.log" 2>&1
        pgrep -f 'bin/ferry-machined' >/dev/null 2>&1 && break
        n=$((n + 1)); sleep 2
      done
      kc=$("$FERRY" kubeconfig)
      KUBECONFIG="$kc" kubectl apply -f - >>"$RESULTS/$s-up.log" 2>&1 <<YAML
apiVersion: ferry.dev/v1alpha1
kind: Machine
metadata:
  name: worker-0
spec:
  cpus: $MACHINE_CPUS
  memory: $MACHINE_MEM
YAML
      # wait_ready only checks the nodes that exist; give the Machine's node
      # time to appear before it starts counting them.
      for _ in $(seq 1 180); do
        KUBECONFIG="$kc" kubectl get node worker-0 >/dev/null 2>&1 && break
        sleep 1
      done ;;
    kind)
      # kubeadm v1beta4 spells kubeletExtraArgs as a list of name/value pairs;
      # the map form that every older example shows is rejected outright by
      # v1.37's kubeadm, and kind reports it as a cluster that failed to come
      # up rather than as a bad patch.
      # ${cfg[@]+...} below: an empty array under `set -u` on bash 3.2 is an
      # unbound variable, and this path is the one taken whenever KUBELET_V is
      # unset -- which is most of the time.
      local cfg=() kindcfg="$BENCH_HOME/.kind-config.yaml"
      if [ -n "$KUBELET_V" ]; then
        cat > "$kindcfg" <<YAML
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
      - name: v
        value: "$KUBELET_V"
YAML
        cfg=(--config "$kindcfg")
      fi
      kind create cluster --name "$CLUSTER" --kubeconfig "$kc" \
                --image "$KIND_NODE_IMAGE" ${cfg[@]+"${cfg[@]}"} \
                >"$RESULTS/$s-up.log" 2>&1 ;;
    minikube) KUBECONFIG="$kc" minikube start -p "$CLUSTER" --driver=docker \
                --kubernetes-version="$K8S_VERSION" \
                --interactive=false >"$RESULTS/$s-up.log" 2>&1 ;;
  esac
}

stack_down() {
  local s="$1" kc; kc=$(kubeconfig_of "$s")
  case "$s" in
    ferry|ferry2) "$FERRY" down --purge >"$RESULTS/$s-down.log" 2>&1 ;;
    kind)     kind delete cluster --name "$CLUSTER" --kubeconfig "$kc" \
                >"$RESULTS/$s-down.log" 2>&1 ;;
    minikube) KUBECONFIG="$kc" minikube delete -p "$CLUSTER" \
                >"$RESULTS/$s-down.log" 2>&1 ;;
  esac
}

# Disk the cluster occupies. ferry keeps its state in the checkout; kind and
# minikube keep theirs in a Docker volume inside the VM.
stack_disk_mib() {
  case "$1" in
    # FERRY_HOME, not ~/.ferry: under a profile the state lives in
    # ~/.ferry-<profile>, and the hardcoded path measured whichever unrelated
    # cluster happened to own the default directory -- or nothing at all.
    ferry|ferry2)
      # Derived from the kubeconfig ferry reports, which is
      # $FERRY_HOME/admin.conf -- there is no `ferry home`, and re-deriving
      # the profile suffix here would be a second place to get it wrong.
      local home; home="$(dirname "$("$FERRY" kubeconfig 2>/dev/null)")"
      [ -d "$home" ] || home="${FERRY_HOME:-$HOME/.ferry}"
      du -sm "$home" 2>/dev/null | awk '{print $1}' ;;
    # The node's writable layer plus its volumes, as a number rather than
    # three lines of `docker system df -v` for a human to read.
    *)
      docker ps -a --filter "name=$CLUSTER" --format '{{.Size}}' 2>/dev/null \
        | awk '{ v=$1; u=toupper(v); sub(/[A-Za-z]+$/,"",v)
                 if (u ~ /GB$/) v*=1024; else if (u ~ /KB$/) v/=1024
                 t+=v } END { printf "%.0f", t+0 }' ;;
  esac
}
