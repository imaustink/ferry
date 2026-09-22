#!/usr/bin/env bash
# Does the kubelet issue its CRI calls concurrently, or one after another?
#
# criconc.sh shows ferry's containerd doing RunPodSandbox in 6.5ms apiece when
# twelve are issued at once, and 38.2ms apiece when they are issued one at a
# time -- against kind's 16.6 and 55.2. So ferry's runtime is the faster of the
# two and parallelises better, yet ferry's pods arrive 35ms apart against
# kind's 11ms.
#
# That only fits if the calls are not being issued together. containerd logs
# each RunPodSandbox when it arrives and again when it returns, so its own log
# says which: gaps between *arrivals* are the kubelet pacing itself, gaps
# between arrival and return are the runtime being slow.
set -uo pipefail
cd "$(dirname "$0")"

STACK="${1:?usage: criseq.sh ferry|kind}"
N="${N:-20}"

case "$STACK" in
  ferry) kc="$(cd ../.. && ./ferry kubeconfig)"; node=perf-0
         sel='      nodeSelector: {ferry.dev/mode: shared}' ;;
  kind)  kc="$HOME/.kube/config-perfk"
         node="$(KUBECONFIG=$kc kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
         sel='' ;;
  *) echo "usage: criseq.sh ferry|kind" >&2; exit 2 ;;
esac
export KUBECONFIG="$kc"

kubectl create namespace criseq >/dev/null 2>&1
kubectl -n criseq delete deployment cs --ignore-not-found >/dev/null 2>&1
sleep 5

if [ "$STACK" = ferry ]; then
  kubectl delete pod seqprobe --ignore-not-found >/dev/null 2>&1
  sleep 2
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: seqprobe}
spec:
  nodeName: $node
  terminationGracePeriodSeconds: 0
  containers:
  - name: c
    image: alpine:3.20
    command: ["sleep","3600"]
    securityContext: {privileged: true, runAsUser: 0}
    volumeMounts: [{name: h, mountPath: /host}]
  volumes:
  - name: h
    hostPath: {path: /}
YAML
  kubectl wait --for=condition=Ready pod/seqprobe --timeout=180s >/dev/null 2>&1 || { echo "no probe"; exit 1; }
  mark=$(kubectl exec seqprobe -- sh -c 'wc -l < /host/var/log/containerd.log' 2>/dev/null | tr -d ' \r')
else
  since="$(docker exec "$node" date -u '+%Y-%m-%d %H:%M:%S')"
fi

cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata: {name: cs, namespace: criseq}
spec:
  replicas: $N
  selector: {matchLabels: {app: cs}}
  template:
    metadata: {labels: {app: cs}}
    spec:
      terminationGracePeriodSeconds: 0
$sel
      containers:
      - name: c
        image: alpine:3.20
        command: ["sleep","3600"]
YAML

for _ in $(seq 1 240); do
  r=$(kubectl -n criseq get pods --no-headers 2>/dev/null | awk '$3=="Running"' | wc -l | tr -d ' ')
  [ "${r:-0}" -ge "$N" ] && break
  sleep 1
done
sleep 3

if [ "$STACK" = ferry ]; then
  kubectl exec seqprobe -- sh -c "tail -n +$mark /host/var/log/containerd.log" 2>/dev/null > /tmp/criseq-$STACK.log
  kubectl delete pod seqprobe --ignore-not-found --wait=false >/dev/null 2>&1
else
  docker exec "$node" sh -c "journalctl -u containerd --no-pager --since '$since'" 2>/dev/null > /tmp/criseq-$STACK.log
fi

echo "== $STACK: RunPodSandbox arrivals and returns, from containerd's own log"
python3 - "/tmp/criseq-$STACK.log" <<'PARSE'
import sys, re, datetime, statistics

# containerd logs RFC3339-ish timestamps; journald prefixes its own. Take the
# first timestamp on the line either way.
ts_pat = re.compile(r'(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+)')
arrive, ret = [], []
for line in open(sys.argv[1], errors="replace"):
    is_ret = "RunPodSandbox" in line and "returns sandbox id" in line
    is_arr = "RunPodSandbox for" in line
    if not (is_ret or is_arr):
        continue
    m = ts_pat.search(line)
    if not m:
        continue
    t = datetime.datetime.fromisoformat(m.group(1))
    (ret if is_ret else arrive).append(t)

def gaps(v, label):
    if len(v) < 3:
        print(f"  {label}: only {len(v)} samples"); return
    v.sort()
    span = (v[-1] - v[0]).total_seconds() * 1000
    d = [(v[i+1] - v[i]).total_seconds() * 1000 for i in range(len(v) - 1)]
    print(f"  {label}: n={len(v)}  span={span:7.0f}ms  "
          f"median gap={statistics.median(d):6.1f}ms  max gap={max(d):6.1f}ms")

gaps(arrive, "arrived at containerd")
gaps(ret,    "returned from containerd")
if len(arrive) >= 3 and len(ret) >= 3:
    arrive.sort(); ret.sort()
    print(f"  -> requests spread over {(arrive[-1]-arrive[0]).total_seconds()*1000:.0f}ms; "
          f"if that is most of the burst, the kubelet is pacing them")
PARSE

kubectl -n criseq delete deployment cs --wait=false >/dev/null 2>&1
