#!/usr/bin/env bash
# A subPath that first appears after the claim's image has been formatted: the
# first pod formats it with no subPaths, the second, non-root, mounts a new one
# and writes to it.
set -euo pipefail
kubectl delete pod late1 late2 --ignore-not-found --wait >/dev/null
kubectl delete pvc late --ignore-not-found --wait >/dev/null
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: late}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 64Mi}}
---
apiVersion: v1
kind: Pod
metadata: {name: late1}
spec:
  terminationGracePeriodSeconds: 0
  restartPolicy: Never
  containers:
  - name: c
    image: alpine:3.20
    command: [sh, -c, 'mkdir -p /data/kept && chmod 0700 /data/kept && ls -la /data']
    volumeMounts: [{name: data, mountPath: /data}]
  volumes: [{name: data, persistentVolumeClaim: {claimName: late}}]
YAML
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/late1 --timeout=120s >/dev/null
kubectl logs late1
kubectl delete pod late1 --wait >/dev/null
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Pod
metadata: {name: late2}
spec:
  terminationGracePeriodSeconds: 0
  restartPolicy: Never
  securityContext: {runAsUser: 1000, runAsGroup: 1000}
  containers:
  - name: c
    image: alpine:3.20
    command: [sh, -c, 'id; ls -la /data /data/new; echo ok > /sub/f && echo WROTE-SUBPATH; stat -c "%a %U" /data/kept']
    volumeMounts:
    - {name: data, mountPath: /data}
    - {name: data, mountPath: /sub, subPath: new/dir}
    - {name: data, mountPath: /kept, subPath: kept}
  volumes: [{name: data, persistentVolumeClaim: {claimName: late}}]
YAML
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/late2 --timeout=120s >/dev/null || kubectl get pod late2
kubectl logs late2
kubectl delete pod late2 --wait >/dev/null
kubectl delete pvc late --wait >/dev/null
