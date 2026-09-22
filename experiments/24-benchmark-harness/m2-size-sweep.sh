#!/usr/bin/env bash
# What mode 2's node ceiling costs, and whether shrinking it costs speed.
#
# stacks.sh sizes the node 15Gi to mirror Docker Desktop, on the reasoning that
# "guest memory is lazily backed, so a ceiling it does not touch costs nothing
# (experiment 14)". That is true of the guest's *pages* and false of the guest's
# *kernel*: Apple's config is CONFIG_ARM64_4K_PAGES with SPARSEMEM_VMEMMAP, so
# the kernel allocates a struct page for every 4 KiB of the ceiling at boot, and
# sizes several hash tables from total RAM besides. Those pages are touched, and
# experiment 14 established the host never gets touched pages back.
#
# Measured standalone against ferry's own kernel, guest touching nothing:
#
#     configured   1 GiB  2 GiB  4 GiB  8 GiB  15 GiB
#     footprint    112    136    240    325    469     MiB
#
# -- about 105 MiB fixed plus 2.5% of whatever the ceiling is. At 15Gi that is
# ~330 MiB of mode 2's idle row spent on memory no pod can use.
#
# So the ceiling is worth lowering. The question this answers is what it buys
# and what it costs: for each size, the host memory split (node VM / pod VMs /
# native) and the guest's own used figure, alongside single-pod and 20-pod
# start times. A size that saves 300 MiB and loses the burst is not a win, and
# the burst is the row ferry is already behind kind on.
#
#   ./m2-size-sweep.sh                 # 2Gi 4Gi 8Gi 15Gi
#   SIZES="2Gi 15Gi" ./m2-size-sweep.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/stacks.sh"

SIZES="${SIZES:-2Gi 4Gi 8Gi 15Gi}"
CPUS="${CPUS:-$MACHINE_CPUS}"
SETTLE="${SETTLE:-45}"
BURST="${BURST:-20}"
REPS="${REPS:-3}"

# Median rather than mean: a burst that hits a slow image-cache miss or a vmnet
# hiccup produces one outlier, and with three samples the mean carries a third
# of it into the published cell.
median() { printf '%s\n' "$@" | sort -n | awk '{v[NR]=$1} END{print (NR%2)?v[(NR+1)/2]:(v[NR/2]+v[NR/2+1])/2}'; }

# run.sh defines these on itself rather than in lib.sh, so they do not arrive
# with the source above. Same definitions, so the timings stay comparable.
POD_IMAGE="${POD_IMAGE:-alpine:3.20}"
since() { python3 -c "print(f'{($(now_ms)-$1)/1000:.2f}')"; }

# Asked of ferry rather than assumed. A checkout runs its own profile, so both
# of these are suffixed with it -- and lib.sh's ferry_vm_pids defaults FERRY_RUN
# to the unsuffixed /tmp/ferry-run, which belongs to a different cluster.
FERRY_STATE="$("$FERRY" profile 2>/dev/null | awk '/^  state /{print $2}')"
FERRY_RUN="${FERRY_RUN:-$("$FERRY" profile 2>/dev/null | awk '/^  runtime /{print $2}')}"
export FERRY_RUN
[ -n "$FERRY_STATE" ] || { echo "could not read this checkout's profile"; exit 1; }

kc=""

# Pods are pinned to the node under test, so nothing lands on the Mac's own
# kubelet and quietly turns this into a mode 1 measurement.
manifest() { # n -> file
  # Two statements, not `local n=$1 f=...$n...`: bash expands every word on a
  # `local` line before any of its assignments take effect, so $n there is the
  # loop's subnet counter rather than $1 -- which named both of an iteration's
  # manifests the same file and let the 20-replica one overwrite the 1-replica
  # one. Harmless in this order, a wrong burst if the calls ever swap.
  local n="$1"
  local f="$BENCH_HOME/.m2size-$n.yaml"
  cat > "$f" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: bench, namespace: bench}
spec:
  replicas: $n
  selector: {matchLabels: {app: bench}}
  template:
    metadata: {labels: {app: bench}}
    spec:
      terminationGracePeriodSeconds: 0
      nodeSelector: {kubernetes.io/hostname: worker-0}
      containers:
      - name: c
        image: $POD_IMAGE
        command: ["sleep", "3600"]
YAML
  echo "$f"
}

running_count() {
  KUBECONFIG="$kc" kubectl get pods -n bench --no-headers 2>/dev/null \
    | awk '$3=="Running"' | wc -l | tr -d ' '
}

time_to_running() { # n file -> seconds
  local n="$1" file="$2" t0 deadline
  deadline=$(( $(date +%s) + 300 ))
  t0=$(now_ms)
  KUBECONFIG="$kc" kubectl apply -f "$file" >/dev/null 2>&1 || { echo apply-failed; return 1; }
  while :; do
    [ "$(running_count)" -ge "$n" ] && break
    [ "$(date +%s)" -gt "$deadline" ] && { echo timeout; return 1; }
  done
  since "$t0"
}

clear_pods() {
  KUBECONFIG="$kc" kubectl delete deployment bench -n bench --wait=true >/dev/null 2>&1
  sleep 12
}

# Used memory inside the node VM -- the basis kind is read on, which excludes
# the guest page cache that phys_footprint counts. Both are reported because
# they answer different questions and the report has conflated them.
guest_used() {
  KUBECONFIG="$kc" kubectl run memprobe-$RANDOM --rm -i --restart=Never \
    --image="$POD_IMAGE" --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"worker-0"}}}' \
    -- free -m 2>/dev/null | awk '/^Mem:/{print $2-$7}'
}

# A node VM boots a disk ferry-machined cloned to <state>/<name>.ext4
# (main.go:125 diskPath); a pod VM's disks live under $FERRY_RUN/cri. That open
# file is how the two are told apart.
#
# m2-breakdown.sh tests for "/machines/" instead, which is where the *spec* file
# goes, not the disk -- no VM ever has it open, so every node VM was charged to
# the pod column and node_vm_mib came out 0.
split_footprint() { # -> "node pod host"
  local pid fp node=0 pod=0 host
  for pid in $(ferry_vm_pids); do
    fp=$(footprint_mib "$pid")
    if lsof -p "$pid" -Fn 2>/dev/null | grep -qE "^n$FERRY_STATE/.*\.ext4$"; then
      node=$(python3 -c "print($node+$fp)")
    else
      pod=$(python3 -c "print($pod+$fp)")
    fi
  done
  host=$(footprint_mib $(ferry_host_pids | tr '\n' ' '))
  echo "$node $pod $host"
}

printf '%-6s %10s %10s %10s %10s %10s %9s %9s\n' \
  size node-vm pod-vms native total guest-used 1-pod "${BURST}-pod"

for MEM in $SIZES; do
  TAG="m2size-$MEM"
  "$FERRY" down --purge >/dev/null 2>&1
  sleep 5

  # vmnet holds a subnet well past the process that made it, so each run moves
  # to one this battery has not used rather than waiting on the last one.
  seq_file="$BENCH_HOME/.machine-subnet-seq"
  n=$(( $(cat "$seq_file" 2>/dev/null || echo 29) + 1 ))
  echo "$n" > "$seq_file"
  export FERRY_MACHINE_SUBNET="192.168.$n.0/24"

  "$FERRY" up >"$RESULTS/$TAG-up.log" 2>&1
  for _ in $(seq 1 12); do
    echo "$n" > "$seq_file"
    FERRY_MACHINE_SUBNET="192.168.$n.0/24" \
      "$FERRY" machines enable >>"$RESULTS/$TAG-up.log" 2>&1
    pgrep -f 'bin/ferry-machined' >/dev/null 2>&1 && break
    n=$((n + 1)); sleep 2
  done
  pgrep -f 'bin/ferry-machined' >/dev/null || { echo "$TAG: machined did not start"; continue; }

  kc=$("$FERRY" kubeconfig)
  KUBECONFIG="$kc" kubectl apply -f - >>"$RESULTS/$TAG-up.log" 2>&1 <<YAML
apiVersion: ferry.dev/v1alpha1
kind: Machine
metadata: {name: worker-0}
spec: {cpus: $CPUS, memory: $MEM}
YAML

  ok=""
  for _ in $(seq 1 300); do
    [ "$(KUBECONFIG="$kc" kubectl get node worker-0 \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] \
      && { ok=1; break; }
    sleep 1
  done
  [ -n "$ok" ] || { echo "$TAG: worker-0 never went Ready"; tail -5 "$RESULTS/$TAG-up.log"; continue; }

  KUBECONFIG="$kc" kubectl create namespace bench >/dev/null 2>&1
  sleep "$SETTLE"

  read -r node pod host <<<"$(split_footprint)"
  total=$(python3 -c "print(f'{$node+$pod+$host:.0f}')")
  record "$TAG" node_vm_mib "$node"
  record "$TAG" pod_vm_mib "$pod"
  record "$TAG" host_mib "$host"
  record "$TAG" total_mib "$total"

  # Warm the image cache before timing anything, so the first pod is not timing
  # a pull. The probe below uses the same image, so it warms it too.
  used=$(guest_used)
  record "$TAG" guest_used_mib "$used"

  # Repeated, unlike the memory readings above. Those were flat to within 5 MiB
  # across a 7.5x range of ceiling; the burst was not -- one run per size gave
  # 1.23/1.98/1.97/2.07s, which is the spread ab.sh exists because of. "No speed
  # penalty" needs more than one sample per size to be worth printing, so each
  # timing is the median of $REPS and the raw runs are recorded individually.
  f1=$(manifest 1)
  fb=$(manifest "$BURST")
  ones=() bursts=()
  for i in $(seq 1 "$REPS"); do
    clear_pods
    s=$(time_to_running 1 "$f1"); record "$TAG" "pod_start_s.$i" "$s"; ones+=("$s")
    clear_pods
    s=$(time_to_running "$BURST" "$fb"); record "$TAG" "scale${BURST}_s.$i" "$s"; bursts+=("$s")
  done
  clear_pods
  one=$(median "${ones[@]}");    record "$TAG" pod_start_s_median "$one"
  burst=$(median "${bursts[@]}"); record "$TAG" "scale${BURST}_s_median" "$burst"

  printf '%-6s %10.0f %10.0f %10.0f %10s %10s %9s %9s\n' \
    "$MEM" "$node" "$pod" "$host" "$total" "$used" "$one" "$burst"
done

"$FERRY" down --purge >/dev/null 2>&1
echo "raw rows in $RESULTS/raw.tsv"
