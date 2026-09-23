#!/usr/bin/env bash
# N containers of one image each read the image's /usr, then the
# VM's page cache is read from inside it. One shared lower caches it once; N
# cloned disks cache it N times.
#   pagecache.sh [containers]
set -euo pipefail
n=${1:-4}
image=python:3.12-slim
{
  echo "apiVersion: v1"
  echo "kind: Pod"
  echo "metadata: {name: pagecache}"
  echo "spec:"
  echo "  terminationGracePeriodSeconds: 1"
  echo "  containers:"
  for i in $(seq 1 "$n"); do
    echo "  - name: c$i"
    echo "    image: $image"
    echo "    command: [sh, -c, 'sleep 2; find /usr -type f -exec cat {} + > /dev/null; touch /tmp/done; exec sleep 36000']"
    echo "    resources: {limits: {memory: 512Mi}}"
  done
} > /tmp/ferry-e31-pagecache.yaml
kubectl apply -f /tmp/ferry-e31-pagecache.yaml >/dev/null
kubectl wait --for=condition=Ready pod/pagecache --timeout=300s >/dev/null
for i in $(seq 1 "$n"); do
  until kubectl exec pagecache -c "c$i" -- test -f /tmp/done 2>/dev/null; do sleep 1; done
done
kib=$(kubectl exec pagecache -c c1 -- du -sk /usr | awk '{print $1}')
cached=$(kubectl exec pagecache -c c1 -- awk '/^Cached:/ {print $2}' /proc/meminfo)
echo "containers=$n usr=$((kib / 1024))MiB guest-page-cache=$((cached / 1024))MiB"
kubectl delete pod pagecache --wait=true >/dev/null
