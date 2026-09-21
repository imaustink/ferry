#!/usr/bin/env bash
# Where mode 2's ~41 seconds goes.
#
# The battery timed the whole bring-up as one number. This splits it, because
# "mode 2 is slower than mode 1" is only useful if it says which part is.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/stacks.sh"
SUBNET="${1:-192.168.206.0/24}"

now() { python3 -c 'import time;print(time.time())'; }
lap() { python3 -c "print(f'{$(now)-$1:.2f}')"; }

"$FERRY" down --purge >/dev/null 2>&1; sleep 8
t_all=$(now)

t=$(now); "$FERRY" up >/dev/null 2>&1;                 A=$(lap "$t")
t=$(now); FERRY_MACHINE_SUBNET="$SUBNET" "$FERRY" machines enable >/dev/null 2>&1; B=$(lap "$t")
kc=$("$FERRY" kubeconfig)

t=$(now)
kubectl --kubeconfig "$kc" apply -f - >/dev/null 2>&1 <<YAML
apiVersion: ferry.dev/v1alpha1
kind: Machine
metadata: {name: worker-0}
spec: {cpus: 2, memory: 2Gi}
YAML
for _ in $(seq 1 300); do
  [ "$(kubectl --kubeconfig "$kc" get machine worker-0 -o jsonpath='{.status.phase}' 2>/dev/null)" = Running ] && break
  sleep 0.3
done; C=$(lap "$t")

t=$(now)
for _ in $(seq 1 300); do
  [ "$(kubectl --kubeconfig "$kc" get node worker-0 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] && break
  sleep 0.3
done; D=$(lap "$t")

t=$(now)
for _ in $(seq 1 300); do
  pend=$(kubectl --kubeconfig "$kc" get pods -n kube-system --no-headers 2>/dev/null \
         | awk '$3!="Running" && $3!="Completed"' | wc -l | tr -d ' ')
  [ "${pend:-1}" = 0 ] && break
  sleep 0.3
done; E=$(lap "$t")
TOTAL=$(lap "$t_all")

printf '\n  %-34s %7ss\n' "ferry up (mode 1 control plane)" "$A"
printf '  %-34s %7ss\n' "ferry machines enable" "$B"
printf '  %-34s %7ss\n' "Machine apply -> phase Running" "$C"
printf '  %-34s %7ss\n' "  -> node registers Ready" "$D"
printf '  %-34s %7ss\n' "  -> kube-system pods all Running" "$E"
printf '  %-34s %7ss\n' "TOTAL" "$TOTAL"

t=$(now); "$FERRY" down --purge >/dev/null 2>&1; printf '  %-34s %7ss\n' "ferry down --purge" "$(lap "$t")"
