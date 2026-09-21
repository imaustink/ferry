#!/usr/bin/env bash
# What the battery's own poll loop costs, per stack.
#
# experiments/24-benchmark-harness/run.sh:time_to_running polls
#   kubectl get pods -n bench --no-headers
# as fast as it can until the expected count is Running. Its resolution is
# therefore one iteration of that command, and any pod that becomes Running
# mid-iteration is not noticed until the next one finishes.
#
# That is fine if the two stacks pay the same per iteration. If they do not,
# the loop reports the slower *client* as the slower *cluster*, and the
# difference lands in pod_start_s and scaleN_s where it looks like a property
# of the runtime.
set -uo pipefail
N="${N:-40}"

one() { # label kubeconfig
  local label="$1" kc="$2" t0 t1
  KUBECONFIG="$kc" kubectl get pods -A --no-headers >/dev/null 2>&1   # warm
  t0=$(python3 -c 'import time;print(time.monotonic())')
  for _ in $(seq 1 "$N"); do
    KUBECONFIG="$kc" kubectl get pods -A --no-headers >/dev/null 2>&1
  done
  t1=$(python3 -c 'import time;print(time.monotonic())')
  python3 -c "print(f'  {'$label':<8} {($t1-$t0)/$N*1000:7.1f} ms per iteration  ({$N} iterations)')"
}

echo "== cost of one poll iteration, the battery's own loop"
one ferry "$(cd "$(dirname "$0")" && ./ferry kubeconfig)"
one kind  "$HOME/.kube/config-perfk"
