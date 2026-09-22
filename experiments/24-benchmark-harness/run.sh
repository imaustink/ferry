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
CPU_WINDOW="${CPU_WINDOW:-60}"
# Unset means "wherever the scheduler likes", which for ferry2 is both modes at
# once. node_selector_of pins the stacks that need it; see stacks.sh.
#
# The trailing newline is part of the value, because the template below splices
# it in ahead of `containers:` on the next line -- which is how altbench.sh and
# pleg.sh spell it, as $'...\n'. Command substitution strips trailing newlines,
# so taking it from node_selector_of dropped it and produced
#
#   nodeSelector: {ferry.dev/mode: shared}      containers:
#
# on one line. Every ferry2 battery run since the selector was added died at
# the first apply with a YAML parse error twelve lines from the cause.
if [ -z "${NODE_SELECTOR+set}" ]; then
  NODE_SELECTOR="$(node_selector_of "$STACK")"
  [ -n "$NODE_SELECTOR" ] && NODE_SELECTOR="$NODE_SELECTOR"$'\n'
fi

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
  # Every stack that has a shared guest, read the same way. This used to run
  # for kind and minikube only, which left the report comparing ferry's
  # host-side footprint against their in-guest used. Mode 1 returns "-".
  local g_used g_unavail
  read -r g_used g_unavail <<<"$(guest_mem_mib "$STACK" "${kc:-}")"
  r "${label}.guest_used_mib"   "$g_used"
  r "${label}.guest_unavail_mib" "$g_unavail"
  r "${label}.vm_count"        "$(echo $vms | wc -w | tr -d ' ')"
  r "${label}.cpu_pct"         "$(cpu_of $vms $hosts)"
}

# Average CPU over a window we chose, rather than one the kernel chose.
#
# Reported as percent of one core, so 100 means one core saturated and this
# machine has sixteen. Taken over CPU_WINDOW seconds with the cluster left
# alone, which is what "overhead at rest" has to mean.
measure_cpu() { # label seconds
  local label="$1" secs="${2:-$CPU_WINDOW}" vms hosts a b t0 t1
  vms=$(stack_vm_pids "$STACK" | tr '\n' ' ')
  hosts=$(stack_host_pids "$STACK" | tr '\n' ' ')
  a=$(cpu_seconds_of $vms $hosts); t0=$(now_ms)
  sleep "$secs"
  b=$(cpu_seconds_of $vms $hosts); t1=$(now_ms)
  r "${label}.cpu_core_pct" \
    "$(python3 -c "print(f'{max(0.0,($b-$a))*100000/max(1,$t1-$t0):.1f}')")"
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

# Docker-based stacks get a restarted Docker first, so their baseline is not
# the previous stack's leftovers. See docker_restart in stacks.sh: the VM does
# not release pages when a cluster is deleted, and the battery runs kind before
# minikube, which is exactly how minikube's published host-side row came to be
# a 10 MiB non-result. Skippable for a single-stack run that has just restarted
# Docker anyway.
case "$STACK" in
  kind|minikube)
    if [ "${SKIP_DOCKER_RESTART:-}" != "1" ]; then
      say "restarting Docker Desktop so this stack's baseline is its own"
      docker_restart || exit 1
    fi ;;
esac

pin_docker_vm
say "docker VM is pid $(docker_vm_pid)"
measure_mem baseline
say "baseline CPU over ${CPU_WINDOW}s (nothing of this stack is running yet)"
measure_cpu baseline

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
say "idle CPU over ${CPU_WINDOW}s"
measure_cpu idle
r disk_mib "$(stack_disk_mib "$STACK")"
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
