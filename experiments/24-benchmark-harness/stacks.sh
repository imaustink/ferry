#!/usr/bin/env bash
# One interface per stack: up, down, where its kubeconfig is, and which host
# processes belong to it. Each cluster is created under a name of its own and
# writes its own kubeconfig, so nothing here touches an existing cluster or
# ~/.kube/config.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KC_DIR="$BENCH_HOME/kubeconfigs"; mkdir -p "$KC_DIR"
CLUSTER=bench

# Docker Desktop's VM, recorded before any ferry VM exists so the two can be
# told apart afterwards. Its parent is launchd, not Docker, so parentage is no
# help -- it is simply the VM that was already there.
DOCKER_VM_PID_FILE="$BENCH_HOME/.docker-vm-pid"
docker_vm_pid() { cat "$DOCKER_VM_PID_FILE" 2>/dev/null; }
pin_docker_vm() { vm_pids | head -1 > "$DOCKER_VM_PID_FILE"; }

# Mode 2's node is sized to mirror Docker Desktop's VM, which is what kind and
# minikube get to put their node in. Guest memory is lazily backed, so a ceiling
# it does not touch costs nothing (experiment 14).
MACHINE_CPUS="${MACHINE_CPUS:-10}"
MACHINE_MEM="${MACHINE_MEM:-15Gi}"

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
    ferry|ferry2) vm_pids | grep -v "^${d}$" ;;
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
    kind)     kind create cluster --name "$CLUSTER" --kubeconfig "$kc" \
                >"$RESULTS/$s-up.log" 2>&1 ;;
    minikube) KUBECONFIG="$kc" minikube start -p "$CLUSTER" --driver=docker \
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
    ferry|ferry2) du -sm "$HOME/.ferry" 2>/dev/null | awk '{print $1}' ;;
    *)     docker system df -v 2>/dev/null \
             | awk -v n="$CLUSTER" '$1 ~ n {print $0}' | head -3 ;;
  esac
}
