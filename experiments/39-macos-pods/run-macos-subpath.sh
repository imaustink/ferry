#!/usr/bin/env bash
# Does subPath work on a macOS pod? The kubelet resolves subPath before the CRI,
# so a single key of a ConfigMap should land at an exact file path, and a
# subdirectory of an emptyDir should mount alone. Boots mac-0 if not up.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
state=$("$here/../../ferry" profile | awk '$1 == "state" {print $2}')
export KUBECONFIG="$state/admin.conf"
k() { kubectl "$@"; }
img=example.com/podsrv-darwin:3

k apply -f "$here/macos-machine.yaml" >/dev/null
for _ in $(seq 180); do k get node mac-0 >/dev/null 2>&1 && break; sleep 1; done
k wait --for=condition=Ready node/mac-0 --timeout=180s >/dev/null || { echo "mac-0 not Ready"; exit 1; }

k delete pod subp --ignore-not-found --wait=true >/dev/null 2>&1
k delete cm app-config --ignore-not-found >/dev/null 2>&1
k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata: {name: app-config, labels: {experiment: "39"}}
data:
  app.conf: "listen = 8080"
  other.conf: "should not appear beside app.conf"
---
apiVersion: v1
kind: Pod
metadata: {name: subp, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-macos-shared
  nodeSelector: {kubernetes.io/hostname: mac-0}
  restartPolicy: Never
  volumes:
    - {name: cfg, configMap: {name: app-config}}
    - {name: work, emptyDir: {}}
  containers:
    - name: c
      image: $img
      command: [/bin/sh, -c]
      args:
        - |
          echo "the file mounted by subPath:"
          cat /etc/app/app.conf
          echo "is other.conf beside it? (want: no)"
          ls /etc/app
          echo "the emptyDir subPath is writable:"
          echo hi > /data/sub/file && cat /data/sub/file
      volumeMounts:
        - {name: cfg, mountPath: /etc/app/app.conf, subPath: app.conf}
        - {name: work, mountPath: /data/sub, subPath: nested}
EOF
for _ in $(seq 120); do
    case "$(k get pod subp -o jsonpath='{.status.phase}')" in Succeeded|Failed) break ;; esac
    sleep 1
done
echo "=== subPath on a macOS pod: $(k get pod subp -o jsonpath='{.status.phase}')"
k logs subp 2>&1 | sed 's/^/    /'
k delete pod subp --wait=false >/dev/null 2>&1
k delete cm app-config >/dev/null 2>&1
