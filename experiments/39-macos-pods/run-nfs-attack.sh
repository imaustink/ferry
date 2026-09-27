#!/usr/bin/env bash
# Can one pod on a shared macOS machine read another's volumes by speaking NFS
# from userspace to the runtime's loopback NFS servers?
#
#   victim    a pod with a PVC, an emptyDir and a Secret, all mounted over NFS
#   attacker  an ordinary pod on the same machine, running nfsprobe: MOUNT the
#             kubelet's pods directory from the kernel's mountd, and every
#             listening loopback port as a per-PV server
#
# Every line should say "refused". Boots mac-0 if it is not up.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
state=$("$here/../../ferry" profile | awk '$1 == "state" {print $2}')
export KUBECONFIG="$state/admin.conf"
k() { kubectl "$@"; }
img=example.com/podsrv-darwin:3
probe=example.com/nfsprobe-darwin:1

(cd "$here/ferry-darwin" && GOOS=darwin GOARCH=arm64 go build -o "$here/build/nfsprobe-img/bin/nfsprobe" ./cmd/nfsprobe) || exit 1
(cd "$here/mkimage" && go build -o "$here/build/mkimage" .) || exit 1
rm -rf "$here/build/nfsprobe-layout"
"$here/build/mkimage" -dir "$here/build/nfsprobe-img" -name "$probe" -entrypoint /bin/nfsprobe \
    -out "$here/build/nfsprobe-layout" >/dev/null || exit 1
"$here/../../bin/ferry-registry" add --store "$state/registry" "$here/build/nfsprobe-layout" >/dev/null || exit 1

k apply -f "$here/macos-machine.yaml" >/dev/null
for _ in $(seq 180); do k get node mac-0 >/dev/null 2>&1 && break; sleep 1; done
k wait --for=condition=Ready node/mac-0 --timeout=180s >/dev/null || { echo "mac-0 not Ready"; exit 1; }

k delete pod victim attacker --ignore-not-found --wait=true >/dev/null 2>&1
k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata: {name: victim-secret, labels: {experiment: "39"}}
stringData: {password: hunter2}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: victim-data, labels: {experiment: "39"}}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: Pod
metadata: {name: victim, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-macos-shared
  nodeSelector: {kubernetes.io/hostname: mac-0}
  volumes:
    - {name: data, persistentVolumeClaim: {claimName: victim-data}}
    - {name: scratch, emptyDir: {}}
    - {name: secret, secret: {secretName: victim-secret}}
  containers:
    - name: v
      image: $img
      command: [/bin/sh, -c, 'echo private > /data/victims-file; echo private > /scratch/victims-file; sleep 600']
      volumeMounts: [{name: data, mountPath: /data}, {name: scratch, mountPath: /scratch}, {name: secret, mountPath: /secret}]
EOF
k wait --for=condition=Ready pod/victim --timeout=120s >/dev/null || { echo "victim not Ready"; k describe pod victim | tail -5; exit 1; }
k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: attacker, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-macos-shared
  nodeSelector: {kubernetes.io/hostname: mac-0}
  restartPolicy: Never
  containers:
    - name: a
      image: $probe
      command: [/bin/sh, -c, '/bin/nfsprobe kernel /private/var/ferry/node/kubelet/pods; /bin/nfsprobe scan 49152 65535']
EOF
for _ in $(seq 180); do
    case "$(k get pod attacker -o jsonpath='{.status.phase}')" in Succeeded|Failed) break ;; esac
    sleep 1
done
echo "=== the attacker, an ordinary pod beside the victim on mac-0"
k logs attacker 2>&1 | sed 's/^/    /'
echo "--- the runtime"
grep -a "require\|refused an NFS" "$state/machined/mac-0.macvm.logs/runtime.log" | tail -3 | cut -c1-200 | sed 's/^/    /'
k delete pod victim attacker --wait=false >/dev/null 2>&1
k delete pvc victim-data --wait=false >/dev/null 2>&1
k delete secret victim-secret >/dev/null 2>&1
