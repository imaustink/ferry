#!/usr/bin/env bash
# The battery, run once per stack.
#
#   ferry     control plane native on macOS, one VM per pod
#   kind      one Docker container as the node, pods share its kernel
#   minikube  same shape, its own node image and addons
#
# Order matters: the first create of each stack pulls its artifacts (node
# image, kicbase, guest kernel) and is timed separately from the second, which
# is what creating a cluster costs once a machine has used the tool before.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/stacks.sh"

STACK="$1"
POD_IMAGE="${POD_IMAGE:-alpine:3.20}"
LAT_REPS="${LAT_REPS:-5}"
SCALES="${SCALES:-10 20}"
QUIESCE="${QUIESCE:-45}"

kc=""; ctx=""
say() { printf '\n== %s: %s\n' "$STACK" "$*"; }
r()   { record "$STACK" "$1" "$2"; }

# Elapsed seconds, two decimals.
since() { python3 -c "print(f'{($(now_ms)-$1)/1000:.2f}')"; }

measure_mem() { # label
  local label="$1" vms hosts fp_vm fp_host used
  vms=$(stack_vm_pids "$STACK" | tr '\n' ' ')
  hosts=$(stack_host_pids "$STACK" | tr '\n' ' ')
  used=$(used_mib)
  fp_vm=$(footprint_mib $vms)
  fp_host=$(footprint_mib $hosts)
  r "${label}.used_mib"        "$used"
  r "${label}.vm_footprint"    "$fp_vm"
  r "${label}.vm_rss"          "$(rss_mib $vms)"
  r "${label}.host_footprint"  "$fp_host"
  r "${label}.host_rss"        "$(rss_mib $hosts)"
  case "$STACK" in ferry|ferry2) ;; *) r "${label}.guest_used_mib" "$(docker_guest_used_mib)" ;; esac
  r "${label}.vm_count"        "$(echo $vms | wc -w | tr -d ' ')"
  r "${label}.cpu_pct"         "$(cpu_of $vms $hosts)"
}

# Wall time from `kubectl apply` to every replica Running, polled tightly.
time_to_running() { # n manifest_file -> seconds
  local n="$1" file="$2" t0 running deadline
  [ -s "$file" ] || { echo "no-manifest"; return 1; }
  deadline=$(( $(date +%s) + 300 ))
  t0=$(now_ms)
  if ! k "$kc" "$ctx" apply -f "$file" >"$RESULTS/$STACK-apply.log" 2>&1; then
    echo "apply-failed"; return 1
  fi
  while :; do
    running=$(k "$kc" "$ctx" get pods -n bench --no-headers 2>/dev/null \
      | awk '$3=="Running"' | wc -l | tr -d ' ')
    [ "${running:-0}" -ge "$n" ] && break
    [ "$(date +%s)" -gt "$deadline" ] && { echo "timeout"; return 1; }
  done
  since "$t0"
}

deployment() { # n -> file
  local n="$1"
  local f="$BENCH_HOME/.dep-$n.yaml"
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
${NODE_SELECTOR:-}      containers:
      - name: c
        image: $POD_IMAGE
        command: ["sleep", "3600"]
YAML
  echo "$f"
}

# ---------------------------------------------------------------- run ----

pin_docker_vm
say "docker VM is pid $(docker_vm_pid)"
measure_mem baseline

say "first create (includes pulling the stack's own artifacts)"
t0=$(now_ms); stack_up "$STACK"
kc=$(kubeconfig_of "$STACK"); ctx=$(context_of "$STACK")
if wait_ready "$kc" "$ctx" 600; then r create_cold_s "$(since "$t0")"
else r create_cold_s FAILED; tail -20 "$RESULTS/$STACK-up.log"; exit 1; fi

k "$kc" "$ctx" version -o json 2>/dev/null | python3 -c \
  'import json,sys; d=json.load(sys.stdin); print("server", d["serverVersion"]["gitVersion"], d["serverVersion"].get("platform",""))' \
  | while read -r _ v p; do record "$STACK" k8s_version "$v"; record "$STACK" platform "$p"; done

say "settling ${QUIESCE}s, then idle cost"
quiesce "$QUIESCE"
measure_mem idle
r idle_nodes "$(k "$kc" "$ctx" get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
r idle_syspods "$(k "$kc" "$ctx" get pods -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"

k "$kc" "$ctx" create namespace bench >/dev/null 2>&1

say "warming the image cache with one throwaway pod"
f=$(deployment 1)
w=$(time_to_running 1 "$f")
case "$w" in timeout|apply-failed|no-manifest)
  echo "warm-up failed: $w"; cat "$RESULTS/$STACK-apply.log" 2>/dev/null; exit 1 ;;
esac
r warmup_pull_s "$w"
k "$kc" "$ctx" delete deployment bench -n bench --wait=true >/dev/null 2>&1
sleep 10

say "single-pod start, $LAT_REPS times, image already cached"
for i in $(seq 1 "$LAT_REPS"); do
  s=$(time_to_running 1 "$f")
  r "pod_start_s.$i" "$s"
  k "$kc" "$ctx" delete deployment bench -n bench --wait=true >/dev/null 2>&1
  sleep 8
done

for n in $SCALES; do
  say "scaling to $n pods"
  f=$(deployment "$n")
  s=$(time_to_running "$n" "$f")
  r "scale${n}_s" "$s"
  sleep 20
  measure_mem "scale$n"
  k "$kc" "$ctx" delete deployment bench -n bench --wait=true >/dev/null 2>&1
  sleep 20
done

say "deleting the cluster"
t0=$(now_ms); stack_down "$STACK"; r delete_s "$(since "$t0")"

say "second create, artifacts now cached"
sleep 15
t0=$(now_ms); stack_up "$STACK"
if wait_ready "$kc" "$ctx" 600; then r create_warm_s "$(since "$t0")"
else r create_warm_s FAILED; fi
stack_down "$STACK"

say "done"
