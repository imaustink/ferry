#!/usr/bin/env bash
# A PersistentVolumeClaim in a macOS pod: written by one macOS pod, read back
# by a second after the first is gone, and then by a Linux pod VM on the Mac --
# one claim, one directory on the Mac, whichever kind of pod has it.
# Boots mac-0 if it is not up.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
state=$("$here/../../ferry" profile | awk '$1 == "state" {print $2}')
export KUBECONFIG="$state/admin.conf"
k() { kubectl "$@"; }
img=example.com/podsrv-darwin:3
done_phase() {
    for _ in $(seq 120); do
        case "$(k get pod "$1" -o jsonpath='{.status.phase}')" in Succeeded|Failed) return ;; esac
        sleep 1
    done
}

k apply -f "$here/macos-machine.yaml" >/dev/null
for _ in $(seq 180); do k get node mac-0 >/dev/null 2>&1 && break; sleep 1; done
k wait --for=condition=Ready node/mac-0 --timeout=180s >/dev/null || { echo "mac-0 not Ready"; exit 1; }

k delete pod pv-writer pv-reader pv-linux --ignore-not-found --wait=true >/dev/null 2>&1
k delete pvc macos-data --ignore-not-found --wait=true >/dev/null 2>&1
k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: macos-data, labels: {experiment: "39"}}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: Pod
metadata: {name: pv-writer, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-macos-shared
  restartPolicy: Never
  volumes: [{name: data, persistentVolumeClaim: {claimName: macos-data}}]
  containers:
    - name: w
      image: $img
      command: [/bin/sh, -c, 'echo "written on \$(sw_vers -productName) \$(sw_vers -productVersion) by uid \$(id -u)" > /data/note; mkdir -p /data/dir; date > /data/dir/when; ls -ln /data']
      volumeMounts: [{name: data, mountPath: /data}]
EOF
done_phase pv-writer
echo "=== a macOS pod writes to the claim"
echo "    pv-writer: $(k get pod pv-writer -o jsonpath='{.status.phase}') on $(k get pod pv-writer -o jsonpath='{.spec.nodeName}')"
k logs pv-writer 2>&1 | sed 's/^/    /'
pv=$(k get pvc macos-data -o jsonpath='{.spec.volumeName}')
echo "    claim bound to $pv, a hostPath at $(k get pv "$pv" -o jsonpath='{.spec.hostPath.path}')"
k delete pod pv-writer --wait=true >/dev/null 2>&1

k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: pv-reader, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-macos-shared
  restartPolicy: Never
  volumes: [{name: data, persistentVolumeClaim: {claimName: macos-data}}]
  containers:
    - name: r
      image: $img
      command: [/bin/sh, -c, 'cat /data/note; cat /data/dir/when']
      volumeMounts: [{name: data, mountPath: /data}]
EOF
done_phase pv-reader
echo "=== a second macOS pod, after the first is gone"
k logs pv-reader 2>&1 | sed 's/^/    /'
k delete pod pv-reader --wait=true >/dev/null 2>&1

k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: pv-linux, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-vm
  restartPolicy: Never
  volumes: [{name: data, persistentVolumeClaim: {claimName: macos-data}}]
  containers:
    - name: r
      image: busybox:1.36
      command: [sh, -c, 'echo "read on \$(uname -sr):"; cat /data/note']
      volumeMounts: [{name: data, mountPath: /data}]
EOF
done_phase pv-linux
echo "=== a Linux pod VM on the Mac, the same claim"
k logs pv-linux 2>&1 | sed 's/^/    /'
echo "    and on the Mac itself: $(cat "$(k get pv "$pv" -o jsonpath='{.spec.hostPath.path}')/note" 2>&1)"

k delete pod pv-linux --wait=true >/dev/null 2>&1
k delete pvc macos-data --wait=false >/dev/null 2>&1
grep -a "nfsd exports\|would not export" "$state/machined/mac-0.macvm.logs/runtime.log" | tail -2 | sed 's/^/    /'
