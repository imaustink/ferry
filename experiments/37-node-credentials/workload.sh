#!/usr/bin/env bash
# One pod, one claim and one Service per node, then exec, logs, port-forward,
# DNS and a ClusterIP from each; and which nodes advertise the GPU.
# usage: workload.sh <node>...   with KUBECONFIG pointing at the cluster (admin)
# NO_PVC="<node> ..." mounts an emptyDir in those nodes' pods; their claim is made and left unused.
set -u
K=kubectl
i=0
for node in "$@"; do
  $K delete pod "e37-$i" --ignore-not-found --wait=true >/dev/null 2>&1
  $K delete pvc "e37-$i" --ignore-not-found --wait=true >/dev/null 2>&1
  volume="persistentVolumeClaim: {claimName: e37-$i}"
  case " ${NO_PVC:-} " in *" $node "*) volume="emptyDir: {}" ;; esac
  $K apply -f - >/dev/null <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: e37-$i}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 16Mi}}
---
apiVersion: v1
kind: Pod
metadata: {name: e37-$i, labels: {app: e37-$i}}
spec:
  nodeSelector: {kubernetes.io/hostname: $node}
  containers:
  - name: web
    image: docker.io/library/busybox:1.36
    command: ["sh", "-c", "echo e37-$i > /data/index.html && echo started on $node && httpd -f -h /data -p 80"]
    volumeMounts: [{name: data, mountPath: /data}]
  volumes:
  - name: data
    $volume
---
apiVersion: v1
kind: Service
metadata: {name: e37-$i}
spec:
  selector: {app: e37-$i}
  ports: [{port: 80}]
YAML
  i=$((i + 1))
done
n=$i
start=$(date +%s)
for i in $(seq 0 $((n - 1))); do
  $K wait --for=condition=Ready "pod/e37-$i" --timeout=180s >/dev/null 2>&1
done
echo "pods Ready or timed out after $(( $(date +%s) - start ))s"
$K get pods -o wide -l 'app in (e37-0,e37-1,e37-2,e37-3,e37-4)' 2>/dev/null
$K get pvc 2>/dev/null | grep e37
port=0
for i in $(seq 0 $((n - 1))); do
  pod="e37-$i" next="e37-$(( (i + 1) % n ))"
  echo "== $pod on $($K get pod "$pod" -o jsonpath='{.spec.nodeName}')"
  printf '  %-28s %s\n' "exec" "$($K exec "$pod" -- cat /data/index.html 2>&1 | tail -1)"
  printf '  %-28s %s\n' "logs" "$($K logs "$pod" 2>&1 | head -1)"
  printf '  %-28s %s\n' "DNS $next" "$($K exec "$pod" -- nslookup "$next.default.svc.cluster.local" 2>&1 | grep -A1 '^Name:' | tail -1)"
  printf '  %-28s %s\n' "ClusterIP $next" "$($K exec "$pod" -- wget -q -T 3 -O - "http://$next/" 2>&1 | tail -1)"
  port=$((37080 + i))
  $K port-forward "pod/$pod" "$port:80" >/dev/null 2>&1 &
  pf=$!
  sleep 2
  printf '  %-28s %s\n' "port-forward :$port" "$(curl -s --max-time 3 "http://127.0.0.1:$port/" || echo FAILED)"
  kill "$pf" 2>/dev/null; wait "$pf" 2>/dev/null
done
echo "== ferry.dev/gpu capacity"
$K get nodes -o custom-columns='NODE:.metadata.name,GPU:.status.capacity.ferry\.dev/gpu,READY:.status.conditions[?(@.type=="Ready")].status'
[ -n "${KEEP:-}" ] && exit 0
for i in $(seq 0 $((n - 1))); do
  $K delete pod "e37-$i" --wait=false >/dev/null 2>&1
  $K delete svc "e37-$i" >/dev/null 2>&1
  $K delete pvc "e37-$i" --wait=false >/dev/null 2>&1
done
