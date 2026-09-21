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
                --image "$KIND_NODE_IMAGE" "${cfg[@]}" \
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
