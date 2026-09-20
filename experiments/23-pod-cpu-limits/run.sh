#!/usr/bin/env bash
# Does a pod's CPU limit reach the cgroup inside its VM, and does it bite?
#
# Needs a running cluster:
#
#   ferry up && export KUBECONFIG="$(ferry kubeconfig)"
#   ./experiments/23-pod-cpu-limits/run.sh
#
# Two questions, because configuring a quota and enforcing one are different
# claims. First every pod's cpu.max is read from inside its own container and
# compared against what its spec asked for. Then two of them are loaded with
# more workers than they are allowed and the cgroup's own accounting is read
# back: the one with a limit should be held to it and say it was throttled, and
# the one without should take the whole machine and say it was not.
#
# The pods are applied in two rounds. Six of them together request 6.6 CPUs,
# and the seventh asks for 4 on a ten-core Mac, so it goes on its own -- a
# scheduler refusal, not a runtime one.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }

command -v kubectl >/dev/null || { echo "kubectl is not on PATH" >&2; exit 1; }
kubectl get nodes >/dev/null 2>&1 || {
  echo "no cluster: run 'ferry up' and export KUBECONFIG=\"\$(ferry kubeconfig)\"" >&2
  exit 1
}

cleanup() {
  kubectl delete --ignore-not-found --wait=false \
    -f "$here/pods.yaml" -f "$here/pod-oversize.yaml" >/dev/null 2>&1
}
trap cleanup EXIT

# cpu.max is "<quota> <period>" in microseconds, or "max <period>" for no
# limit, read from inside the container so it is the container's own cgroup and
# not the pod's. nproc is the VM's vCPU count, which is a different decision
# made in a different place -- runPodSandbox, from the pod spec -- and is here
# to show the quota never exceeds the machine it runs on.
measure() { # pod [container]
  local pod="$1" ctr="${2:-}" args=()
  [ -n "$ctr" ] && args=(-c "$ctr")
  # An empty array is not expandable under set -u on bash 3.2, which is what
  # /bin/bash on macOS still is.
  kubectl exec "$pod" ${args[@]+"${args[@]}"} -- \
    sh -c 'echo "$(cat /sys/fs/cgroup/cpu.max) $(nproc)"' 2>/dev/null | tr -d '\r' | tail -1
}

expect() { # description pod container want-cpu.max want-nproc
  local description="$1" got want="$4 $5"
  got="$(measure "$2" "$3")"
  if [ "$got" = "$want" ]; then ok "$description"; else
    bad "$description"; echo "      want '$want', got '$got'"
  fi
}

# Load the container with four busy workers for five seconds and read the
# cgroup's own accounting back. usage_usec is CPU time actually granted, so a
# container held to one CPU reports about five seconds of it against five
# seconds of wall clock, and one held to none reports as much as the machine
# could give. nr_throttled counts the 100ms periods the quota ran out in.
load() { # pod -> "<cpu-seconds*10> <throttled-periods>"
  kubectl exec "$1" -- sh -c '
    b=$(awk "/usage_usec/{print \$2}" /sys/fs/cgroup/cpu.stat)
    t=$(awk "/nr_throttled/{print \$2}" /sys/fs/cgroup/cpu.stat)
    for i in 1 2 3 4; do (while :; do :; done) & done
    sleep 5
    kill %1 %2 %3 %4 2>/dev/null
    a=$(awk "/usage_usec/{print \$2}" /sys/fs/cgroup/cpu.stat)
    t2=$(awk "/nr_throttled/{print \$2}" /sys/fs/cgroup/cpu.stat)
    echo "$(( (a-b)/100000 )) $((t2-t))"
  ' 2>/dev/null | tr -d '\r' | tail -1
}

wait_running() { # pod...
  local waited=0 pod
  for pod in "$@"; do
    while [ "$(kubectl get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Running" ]; do
      waited=$((waited + 2))
      [ "$waited" -gt 300 ] && { echo "timed out waiting for $pod" >&2; kubectl get pods >&2; return 1; }
      sleep 2
    done
  done
}

cleanup; sleep 2
kubectl apply -f "$here/pods.yaml" >/dev/null
wait_running cpu-limit-2 cpu-besteffort cpu-request-only cpu-fractional \
             cpu-two-containers cpu-sub-one || exit 1

printf '\033[1m%s\033[0m\n' "a limit reaches the container's cgroup"
expect "2 CPUs asks for two periods' worth"   cpu-limit-2        "" "200000" "100000 2"
expect "1500m rounds up rather than down"     cpu-fractional     "" "200000" "100000 2"
expect "100m lands on the floor of one CPU"   cpu-sub-one        "" "100000" "100000 2"
expect "each of two containers gets its own"  cpu-two-containers "a" "100000" "100000 2"
expect "and the other is bounded separately"  cpu-two-containers "b" "100000" "100000 2"

printf '\033[1m%s\033[0m\n' "no limit means no limit"
expect "BestEffort is unbounded"              cpu-besteffort     "" "max" "100000 2"
expect "a request alone does not become one"  cpu-request-only   "" "max" "100000 2"

printf '\033[1m%s\033[0m\n' "and the quota is enforced, not just configured"
# Four workers, five seconds. Tolerances are wide because this is a busy Mac:
# what is being asserted is one CPU versus two, not a stopwatch.
read -r tenths throttled <<<"$(load cpu-sub-one)"
if [ "${tenths:-0}" -ge 40 ] && [ "$tenths" -le 60 ]; then
  ok "100m container got ~1 CPU-second per second (${tenths}e-1 s over 5 s)"
else bad "100m container got ${tenths}e-1 CPU-seconds over 5 s, wanted ~50"; fi
if [ "${throttled:-0}" -gt 0 ]; then
  ok "and the kernel says it throttled it ($throttled periods)"
else bad "but the kernel reported no throttling"; fi

read -r tenths throttled <<<"$(load cpu-besteffort)"
if [ "${tenths:-0}" -ge 80 ]; then
  ok "BestEffort took the whole machine (${tenths}e-1 s over 5 s, 2 vCPU)"
else bad "BestEffort got ${tenths}e-1 CPU-seconds over 5 s, wanted ~100"; fi
if [ "${throttled:-0}" -eq 0 ]; then
  ok "and was never throttled"
else bad "but was throttled $throttled times, which it should never be"; fi

# The seventh pod asks for more CPUs than FERRY_POD_CPUS and more than fits
# beside the others. Its VM is the check that the quota can never exceed the
# machine: the machine grew to match.
printf '\033[1m%s\033[0m\n' "a pod larger than the default machine"
kubectl delete -f "$here/pods.yaml" --wait=true >/dev/null 2>&1
kubectl apply -f "$here/pod-oversize.yaml" >/dev/null
wait_running cpu-limit-4 || exit 1
expect "4 CPUs, in a VM that grew to four"    cpu-limit-4        "" "400000" "100000 4"

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[1m%d passed\033[0m\n' "$pass"
else
  printf '\033[1m%d passed, %d failed\033[0m\n' "$pass" "$fail"
  exit 1
fi
