#!/usr/bin/env bash
# Churns pods on this profile's cluster for a long time and records, after each
# cycle has drained, everything on the Mac that ferry owns. A leak is a count
# that does not come back to where it started.
#   soak.sh [--cycles N] [--hours H] [--workloads scale,job,abort] [--out DIR]
#
# A cycle is each chosen workload once, then a drain: wait until the soak
# namespace has no pods and no pod VM of this profile is left running, and
# take a snapshot. The snapshot is only comparable across cycles because it is
# always taken at the same point -- nothing of the soak's own running.
#
#   scale  a Deployment behind a Service, 0 -> SCALE_N -> 0, with a readiness
#          probe, one exec and one log read. Exercises VMs, the pod network,
#          EndpointSlices and the proxy rules that follow them.
#   job    a Job of JOB_N one-second pods, JOB_P at a time. Short lives, many
#          of them: the whole lifecycle, as fast as it will go.
#   abort  ABORT_N bare pods, each deleted at a random moment 0-3s after it
#          was created -- mid-schedule, mid-boot, mid-network-setup.
#
# Ctrl-C stops after the current step and still writes the report.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
FERRY="${FERRY:-$here/../../ferry}"
export FERRY
NS="${SOAK_NS:-soak}"
export SOAK_NS="$NS"
IMAGE="${SOAK_IMAGE:-busybox:1.36}"
SCALE_N="${SCALE_N:-20}"
JOB_N="${JOB_N:-30}"
JOB_P="${JOB_P:-10}"
ABORT_N="${ABORT_N:-10}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-180}"

cycles=0 hours=0 workloads="scale,job,abort"
out="$here/results/$(date +%Y%m%d-%H%M%S)"
while [ $# -gt 0 ]; do
  case "$1" in
    --cycles) cycles="$2"; shift 2 ;;
    --hours) hours="$2"; shift 2 ;;
    --workloads) workloads="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    *) echo "usage: soak.sh [--cycles N] [--hours H] [--workloads scale,job,abort] [--out DIR]" >&2; exit 2 ;;
  esac
done
[ "$cycles" = 0 ] && [ "$hours" = 0 ] && cycles=10

export KUBECONFIG
KUBECONFIG="$("$FERRY" kubeconfig)" || { echo "no kubeconfig: is this profile's cluster up?" >&2; exit 1; }
kubectl version --request-timeout=5s >/dev/null || { echo "the API server does not answer" >&2; exit 1; }

mkdir -p "$out"
csv="$out/snapshots.csv"
log="$out/events.log"
now() { python3 -c 'import time; print("%.2f" % time.time())'; }
# To stderr: drain() is read through a command substitution, and what it says
# must not end up in the number it returns.
say() { echo "$(date +%H:%M:%S) $*" | tee -a "$log" >&2; }

stop=0
trap 'stop=1; say "interrupted: finishing this step"' INT TERM

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -n "$NS" -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata: {name: churn}
spec:
  selector: {app: churn}
  ports: [{port: 80, targetPort: 8080}]
EOF

record() {
  # $1 cycle, $2 drain seconds, $3 failures this cycle
  local line keys
  line="$("$here/snapshot.sh")"
  if [ ! -f "$csv" ]; then
    keys="$(tr ' ' '\n' <<<"$line" | grep = | cut -d= -f1 | paste -sd, -)"
    echo "cycle,t,drain_s,failures,$keys" > "$csv"
  fi
  echo "$1,$(now),$2,$3,$(tr ' ' '\n' <<<"$line" | grep = | cut -d= -f2 | paste -sd, -)" >> "$csv"
}

our_vms() {
  local run home n=0 pid
  run="$("$FERRY" profile | awk '$1 == "runtime" { print $2 }')"
  home="$(dirname "$KUBECONFIG")"
  for pid in $(pgrep -f Virtualization.VirtualMachine); do
    lsof -n -p "$pid" -Fn 2>/dev/null | grep -qF -e "$run/" -e "$home/" && n=$((n + 1))
  done
  echo "$n"
}

# Pods of this node outside the soak, each of which is a VM that is supposed
# to be there. Counted every time rather than once at the start: CoreDNS may
# still be booting when the soak begins, and a baseline taken then waits
# forever for a VM that was never going to leave.
others() {
  kubectl get pods -A --no-headers --field-selector status.phase=Running 2>/dev/null \
    | awk -v ns="$NS" '$1 != ns' | wc -l | tr -d ' '
}

# Waits until the namespace is empty and the profile has one VM per pod
# outside it. Prints how long that took, or "timeout".
drain() {
  local start pods vms
  start="$(now)"
  while :; do
    pods="$(kubectl get pods -n "$NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    vms="$(our_vms)"
    if [ "$pods" = 0 ] && [ "$vms" -le "$(others)" ]; then
      python3 -c "print('%.1f' % ($(now) - $start))"; return 0
    fi
    if python3 -c "import sys; sys.exit(0 if $(now) - $start > $DRAIN_TIMEOUT else 1)"; then
      echo timeout
      say "drain timed out: pods=$pods vms=$vms (expected $(others))"
      kubectl get pods -n "$NS" -o wide >> "$log" 2>&1
      return 1
    fi
    sleep 2
  done
}

w_scale() {
  kubectl apply -n "$NS" -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: churn}
spec:
  replicas: 0
  selector: {matchLabels: {app: churn}}
  template:
    metadata: {labels: {app: churn}}
    spec:
      terminationGracePeriodSeconds: 2
      containers:
      - name: web
        image: $IMAGE
        command: [sh, -c, 'echo hello > /tmp/index.html; echo started; exec httpd -f -p 8080 -h /tmp']
        readinessProbe: {tcpSocket: {port: 8080}, periodSeconds: 1}
        resources: {requests: {cpu: 10m, memory: 32Mi}}
EOF
  kubectl scale -n "$NS" deploy/churn --replicas="$SCALE_N" >/dev/null
  if ! kubectl rollout status -n "$NS" deploy/churn --timeout=180s >/dev/null 2>&1; then
    say "scale: $SCALE_N replicas not ready in 180s: $(kubectl get deploy -n "$NS" churn --no-headers)"
    # What the stuck ones said, before scaling down takes them away.
    kubectl get pods -n "$NS" -l app=churn -o wide --no-headers | grep -v ' 1/1 ' >> "$log" 2>&1
    kubectl scale -n "$NS" deploy/churn --replicas=0 >/dev/null
    return 1
  fi
  local eps pod fail=0 i
  # The EndpointSlice follows the pods by a moment; a slice still short after
  # ten seconds is not lag.
  for i in $(seq 1 10); do
    eps="$(kubectl get endpointslices -n "$NS" -l kubernetes.io/service-name=churn \
      -o jsonpath='{range .items[*].endpoints[?(@.conditions.ready==true)]}x{"\n"}{end}' | grep -c x)"
    [ "$eps" = "$SCALE_N" ] && break
    sleep 1
  done
  [ "$eps" = "$SCALE_N" ] || { say "scale: $eps ready endpoints for $SCALE_N ready pods after 10s"; fail=1; }
  pod="$(kubectl get pods -n "$NS" -l app=churn -o name | head -1)"
  kubectl exec -n "$NS" "$pod" -- wget -qO- "http://churn.$NS.svc/" 2>/dev/null | grep -q hello \
    || { say "scale: exec+wget through the Service failed from $pod"; fail=1; }
  kubectl logs -n "$NS" "$pod" 2>/dev/null | grep -q started \
    || { say "scale: logs of $pod missing 'started'"; fail=1; }
  kubectl scale -n "$NS" deploy/churn --replicas=0 >/dev/null
  return $fail
}

w_job() {
  kubectl delete job -n "$NS" churn-job --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl apply -n "$NS" -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata: {name: churn-job}
spec:
  completions: $JOB_N
  parallelism: $JOB_P
  backoffLimit: 0
  ttlSecondsAfterFinished: 0
  template:
    spec:
      restartPolicy: Never
      terminationGracePeriodSeconds: 1
      containers:
      - name: once
        image: $IMAGE
        command: [sh, -c, 'sleep 1; echo ok']
        resources: {requests: {cpu: 10m, memory: 16Mi}}
EOF
  local fail=0
  if ! kubectl wait -n "$NS" job/churn-job --for=condition=Complete --timeout=300s >/dev/null 2>&1; then
    say "job: not complete in 300s: $(kubectl get job -n "$NS" churn-job -o jsonpath='{.status}' 2>&1)"
    fail=1
  fi
  kubectl delete job -n "$NS" churn-job --ignore-not-found --wait=false >/dev/null 2>&1
  return $fail
}

w_abort() {
  local i
  for i in $(seq 1 "$ABORT_N"); do
    (
      name="abort-$RANDOM$RANDOM"
      kubectl run -n "$NS" "$name" --image="$IMAGE" --restart=Never \
        --overrides='{"spec":{"terminationGracePeriodSeconds":0}}' -- sleep 3600 >/dev/null 2>&1
      sleep "$(python3 -c 'import random; print("%.2f" % random.uniform(0, 3))')"
      kubectl delete pod -n "$NS" "$name" --grace-period=0 --force --wait=false >/dev/null 2>&1
    ) &
  done
  wait
}

say "soak into $out: workloads=$workloads cycles=$cycles hours=$hours"
record 0 0 0
deadline=0
[ "$hours" != 0 ] && deadline="$(python3 -c "import time; print(time.time() + $hours * 3600)")"

cycle=0
while [ "$stop" = 0 ]; do
  cycle=$((cycle + 1))
  [ "$cycles" != 0 ] && [ "$cycle" -gt "$cycles" ] && break
  [ "$deadline" != 0 ] && python3 -c "import sys, time; sys.exit(0 if time.time() > $deadline else 1)" && break
  failures=0
  for w in ${workloads//,/ }; do
    [ "$stop" = 1 ] && break
    start="$(now)"
    if "w_$w"; then r=ok; else r=FAIL; failures=$((failures + 1)); fi
    say "cycle $cycle $w $r in $(python3 -c "print('%.1f' % ($(now) - $start))")s"
  done
  d="$(drain)" || failures=$((failures + 1))
  record "$cycle" "$d" "$failures"
  say "cycle $cycle drained in ${d}s, $failures failures"
done

kubectl delete deploy -n "$NS" churn --ignore-not-found >/dev/null 2>&1
python3 "$here/report.py" "$csv" | tee "$out/report.txt"
