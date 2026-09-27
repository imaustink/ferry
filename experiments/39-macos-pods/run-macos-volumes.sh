#!/usr/bin/env bash
# Volumes in a macOS pod: a ConfigMap, a Secret, an emptyDir two containers
# share, the pod's own ServiceAccount token used against the API server, the
# kubelet's /etc/hosts, a ConfigMap update arriving in a running pod, a write
# to a read-only volume refused, and a termination message read back.
# Boots mac-0 if it is not up.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
state=$("$here/../../ferry" profile | awk '$1 == "state" {print $2}')
export KUBECONFIG="$state/admin.conf"
k() { kubectl "$@"; }
img=example.com/podsrv-darwin:3

k apply -f "$here/macos-machine.yaml" >/dev/null
for _ in $(seq 180); do k get node mac-0 >/dev/null 2>&1 && break; sleep 1; done
k wait --for=condition=Ready node/mac-0 --timeout=180s >/dev/null || { echo "mac-0 not Ready"; exit 1; }

k delete pod vols term --ignore-not-found >/dev/null 2>&1
k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata: {name: cfg, labels: {experiment: "39"}}
data: {greeting: "hello from a ConfigMap"}
---
apiVersion: v1
kind: Secret
metadata: {name: sec, labels: {experiment: "39"}}
stringData: {password: "hunter2, from a Secret"}
---
apiVersion: v1
kind: Pod
metadata: {name: vols, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-macos-shared
  volumes:
    - {name: config, configMap: {name: cfg}}
    - {name: secret, secret: {secretName: sec}}
    - {name: shared, emptyDir: {}}
  containers:
    - name: writer
      image: $img
      command: [/bin/sh, -c, 'i=0; while true; do i=\$((i+1)); echo "tick \$i from the writer, uid \$(id -u)" > /shared/tick; sleep 1; done']
      volumeMounts: [{name: shared, mountPath: /shared}]
    - name: reader
      image: $img
      command: [/bin/sleep, "3600"]
      volumeMounts:
        - {name: config, mountPath: /config}
        - {name: secret, mountPath: /secret}
        - {name: shared, mountPath: /shared}
---
apiVersion: v1
kind: Pod
metadata: {name: term, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-macos-shared
  restartPolicy: Never
  containers:
    - name: term
      image: $img
      command: [/bin/sh, -c, 'echo "the last thing this container said" > /dev/termination-log; exit 3']
EOF
k wait --for=condition=Ready pod/vols --timeout=120s >/dev/null || { k describe pod vols | tail -15; exit 1; }
sleep 3
x() { k exec vols -c reader -- /bin/sh -c "$1" 2>&1 | sed 's/^/    /'; }

echo "=== ConfigMap, Secret"
x 'cat /config/greeting; echo; cat /secret/password; echo'
echo "=== the emptyDir, written by one container and read by another"
x 'cat /shared/tick; ls -ln /shared'
echo "=== the pod's own ServiceAccount token, against the API server"
x 'ls /var/run/secrets/kubernetes.io/serviceaccount/; T=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token); echo "token: ${#T} bytes"; curl -s --max-time 5 --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt -H "Authorization: Bearer $T" https://kubernetes.default.svc.cluster.local/api/v1/namespaces/default/pods/vols -o /dev/null -w "GET own pod with it: HTTP %{http_code}\n"; curl -s --max-time 5 --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt -H "Authorization: Bearer $T" https://kubernetes.default.svc.cluster.local/version | grep gitVersion'
echo "=== off the cluster: the internet, from the node's address"
x 'curl -s --max-time 10 -o /dev/null -w "https://example.com: HTTP %{http_code}\n" https://example.com'
echo "=== /etc/hosts, from the kubelet"
x 'cat /etc/hosts | grep -v "^#" | grep .'
echo "=== /dev: devfs, as the node has it, with fdesc on top"
x 'ls /dev | tr "\n" " "; echo; echo hi > /dev/null && echo "/dev/null writable"; ls /dev/fd | wc -l | tr -d " " | sed "s/$/ entries in \/dev\/fd/"'
echo "=== a read-only volume refuses a write"
x 'echo x > /config/new && echo "wrote to /config -- should not have" || true'

echo "=== a ConfigMap update reaches the running pod"
k patch configmap cfg -p '{"data":{"greeting":"hello again, updated"}}' >/dev/null
t0=$(date +%s)
for _ in $(seq 120); do
    k exec vols -c reader -- /bin/cat /config/greeting 2>/dev/null | grep -q updated && break
    sleep 1
done
echo "    after $(( $(date +%s) - t0 )) s: $(k exec vols -c reader -- /bin/cat /config/greeting 2>&1)"

echo "=== a termination message"
for _ in $(seq 60); do
    case "$(k get pod term -o jsonpath='{.status.phase}')" in Succeeded|Failed) break ;; esac
    sleep 1
done
k get pod term -o jsonpath='    exit {.status.containerStatuses[0].state.terminated.exitCode}, message: {.status.containerStatuses[0].state.terminated.message}
'

echo "=== delete, and the volumes are unmounted before the roots go"
k delete pod vols term --timeout=60s >/dev/null 2>&1
grep -a "volume\|unmount\|still mounted" "$state/machined/mac-0.macvm.logs/runtime.log" | tail -4 | sed 's/^/    /'
