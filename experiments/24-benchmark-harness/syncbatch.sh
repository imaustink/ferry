#!/usr/bin/env bash
# How many batches does the kubelet learn about a burst in?
#
# criseq.sh shows kind's kubelet issuing all 20 RunPodSandbox calls within 64ms
# and ferry's spreading them over 427ms, while criconc.sh shows ferry's
# containerd being the *faster* of the two. So the runtime is not the limit --
# the kubelet is feeding it in waves.
#
# One explanation is upstream of the kubelet's own logic: it acts on a watch,
# and `HandlePodAdditions` runs once per delivered batch. Kind's apiserver and
# kubelet share a kernel and a loopback; ferry's are a macOS process and a VM.
# If ferry receives the twenty pods in four deliveries, it dispatches in four
# waves no matter how fast anything downstream is.
#
# The kubelet logs "SyncLoop (ADD, ...)" once per batch with the pods in it.
set -uo pipefail
cd "$(dirname "$0")"

N="${N:-20}"
kc="$(cd ../.. && ./ferry kubeconfig)"
export KUBECONFIG="$kc"

kubectl create namespace syncb >/dev/null 2>&1
kubectl -n syncb delete deployment sb --ignore-not-found >/dev/null 2>&1
kubectl delete pod sbprobe --ignore-not-found >/dev/null 2>&1
sleep 5

cat <<'YAML' | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: sbprobe}
spec:
  nodeName: perf-0
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
kubectl wait --for=condition=Ready pod/sbprobe --timeout=180s >/dev/null 2>&1 || { echo "no probe"; exit 1; }
mark=$(kubectl exec sbprobe -- sh -c 'wc -l < /host/var/log/kubelet.log' 2>/dev/null | tr -d ' \r')

cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata: {name: sb, namespace: syncb}
spec:
  replicas: $N
  selector: {matchLabels: {app: sb}}
  template:
    metadata: {labels: {app: sb}}
    spec:
      terminationGracePeriodSeconds: 0
      nodeSelector: {ferry.dev/mode: shared}
      containers:
      - name: c
        image: alpine:3.20
        command: ["sleep","3600"]
YAML

for _ in $(seq 1 240); do
  r=$(kubectl -n syncb get pods --no-headers 2>/dev/null | awk '$3=="Running"' | wc -l | tr -d ' ')
  [ "${r:-0}" -ge "$N" ] && break
  sleep 1
done
sleep 3

kubectl exec sbprobe -- sh -c "tail -n +$mark /host/var/log/kubelet.log" 2>/dev/null > /tmp/syncbatch.log
echo "== ferry: SyncLoop ADD batches for $N pods"
python3 - /tmp/syncbatch.log <<'PARSE'
import sys, re, datetime
# I0921 07:18:22.024591  ... "SyncLoop ADD" source="api" pods=["ns/a","ns/b"]
pat = re.compile(r'^\w(\d{4} \d{2}:\d{2}:\d{2}\.\d+).*SyncLoop \(?ADD')
rows = []
for line in open(sys.argv[1], errors="replace"):
    m = pat.search(line)
    if not m: continue
    n = len(re.findall(r'syncb/', line)) or line.count('"syncb/')
    if n == 0: continue
    t = datetime.datetime.strptime("2026" + m.group(1), "%Y%m%d %H:%M:%S.%f")
    rows.append((t, n))
if not rows:
    print("  no SyncLoop ADD lines mentioning the namespace")
    raise SystemExit(0)
t0 = rows[0][0]
total = 0
for t, n in rows:
    total += n
    print(f"  +{(t - t0).total_seconds()*1000:7.1f}ms   {n:2} pod(s)   running total {total}")
print(f"\n  {len(rows)} batch(es) over {(rows[-1][0]-t0).total_seconds()*1000:.0f}ms for {total} pods")
PARSE

kubectl -n syncb delete deployment sb --wait=false >/dev/null 2>&1
kubectl delete pod sbprobe --ignore-not-found --wait=false >/dev/null 2>&1
