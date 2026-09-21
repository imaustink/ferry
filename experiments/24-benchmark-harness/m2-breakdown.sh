#!/usr/bin/env bash
# Where mode 2's idle memory actually goes.
#
# The report attributed 1432 MiB to "a node VM plus mode 1's CoreDNS pod VM plus
# the control plane" without measuring the split, and the node was sized 10/15Gi
# to mirror Docker Desktop. Both of those are worth checking: a guest's kernel
# structures scale with its configured memory even when the memory is untouched.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/stacks.sh"

CPUS="$1"; MEM="$2"; SUBNET="$3"; TAG="m2-$CPUS-$MEM"

"$FERRY" down --purge >/dev/null 2>&1; sleep 5
"$FERRY" up >/dev/null 2>&1
FERRY_MACHINE_SUBNET="$SUBNET" "$FERRY" machines enable >/dev/null 2>&1
pgrep -f 'bin/ferry-machined' >/dev/null || { echo "$TAG: machined did not start"; exit 1; }

kc=$("$FERRY" kubeconfig)
KUBECONFIG="$kc" kubectl apply -f - >/dev/null 2>&1 <<YAML
apiVersion: ferry.dev/v1alpha1
kind: Machine
metadata: {name: worker-0}
spec: {cpus: $CPUS, memory: $MEM}
YAML
for _ in $(seq 1 240); do
  [ "$(KUBECONFIG="$kc" kubectl get node worker-0 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] && break
  sleep 1
done
sleep 45   # settle

# A pod VM is held by ferry-cri; the node VM is held by ferry-node, which keeps
# its state under $FERRY_RUN/machines. That is how the two are told apart.
d=$(docker_vm_pid)
echo "=== $TAG ==="
node_total=0; pod_total=0
for pid in $(vm_pids | grep -v "^${d}$"); do
  fp=$(footprint_mib "$pid")
  if lsof -p "$pid" -Fn 2>/dev/null | grep -q "/machines/"; then
    kind=node-vm; node_total=$(python3 -c "print($node_total+$fp)")
  else
    kind=pod-vm; pod_total=$(python3 -c "print($pod_total+$fp)")
  fi
  printf '  %-8s pid %-7s %8.1f MiB\n' "$kind" "$pid" "$fp"
done
host=$(footprint_mib $(ferry_host_pids | tr '\n' ' '))
printf '  %-8s %13s %8.1f MiB\n' "host" "(native)" "$host"
python3 -c "print(f'  TOTAL {$node_total + $pod_total + $host:.1f} MiB  (node-vm {$node_total:.1f}, pod-vm {$pod_total:.1f}, host {$host:.1f})')"
record "$TAG" node_vm_mib "$node_total"
record "$TAG" pod_vm_mib "$pod_total"
record "$TAG" host_mib "$host"
KUBECONFIG="$kc" kubectl get pods -A --no-headers 2>/dev/null | awk '{print "  pod: "$1"/"$2" on "}' | head -5
KUBECONFIG="$kc" kubectl get pods -A -o custom-columns=NS:.metadata.namespace,POD:.metadata.name,NODE:.spec.nodeName --no-headers 2>/dev/null
"$FERRY" down --purge >/dev/null 2>&1
