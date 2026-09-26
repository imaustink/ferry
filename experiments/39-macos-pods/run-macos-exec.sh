#!/usr/bin/env bash
# kubectl exec, exec probes and port-forward against pods on the macOS machine.
# Boots mac-0 if it is not up (run-macos-machine.sh leaves it up).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
state=$("$here/../../ferry" profile | awk '$1 == "state" {print $2}')
export KUBECONFIG="$state/admin.conf"
k() { kubectl "$@"; }
img=example.com/podsrv-darwin:3
podsrv="$here/build/netpod/bin/podsrv"

k apply -f "$here/macos-machine.yaml" >/dev/null
k wait --for=condition=Ready node/mac-0 --timeout=180s >/dev/null || { echo "mac-0 not Ready"; exit 1; }

k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: web, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-macos-shared
  containers:
    - name: web
      image: $img
      args: [serve, web]
      # An exec probe: the kubelet's ExecSync, run in the container's root.
      readinessProbe:
        exec: {command: [/bin/hello]}
        periodSeconds: 2
EOF
k wait --for=condition=Ready pod/web --timeout=90s >/dev/null
echo "=== web is $(k get pod web -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' ) Ready, through an exec readinessProbe"
k get pod web -o wide | sed 's/^/    /'

echo "=== kubectl exec web -- /bin/hello probe"
k exec web -- /bin/hello probe 2>&1 | sed 's/^/    /'
echo "=== the exit code comes back: kubectl exec web -- /bin/podsrv get 127.0.0.1 1"
k exec web -- /bin/podsrv get 127.0.0.1 1 2>&1 | sed 's/^/    /'
echo "    kubectl exited ${PIPESTATUS[0]}"
echo "=== with a terminal: kubectl exec -t web -- /bin/hello"
k exec -t web -- /bin/hello 2>&1 | sed 's/^/    /'
echo "=== stdin: echo ... | kubectl exec -i web -- /bin/podsrv echo"
echo "hello through stdin" | k exec -i web -- /bin/podsrv echo 2>&1 | sed 's/^/    /'

echo "=== kubectl port-forward pod/web 18080:8080"
k port-forward pod/web 18080:8080 >/dev/null 2>&1 &
pf=$!
sleep 2
printf '    '; "$podsrv" get 127.0.0.1 18080 2>&1
kill $pf 2>/dev/null

echo "=== a shell in a macOS pod: the node's /bin and /usr/bin, in every root"
k exec web -- /bin/sh -c 'echo "sh, pid $$, uid $(id -u), $(uname -sr)"; echo "/bin: $(ls /bin | wc -l | tr -d " ") tools, /usr/bin: $(ls /usr/bin | wc -l | tr -d " ")"; ls / | tr "\n" " "; echo' 2>&1 | sed 's/^/    /'
# kubectl drops -t unless its own stdin is a terminal, so script(1) gives it one.
script -q /dev/null kubectl exec -it web -- /bin/zsh -c 'echo "zsh $ZSH_VERSION on a tty: $(tty), $(stty size) rows/cols"' < /dev/null 2>&1 | tr -d '\r' | sed 's/^/    /'
k exec web -- /bin/sh -c 'ls -l /usr/bin/sudo | cut -c1-10; echo "sudo is not setuid in a pod root"' 2>&1 | sed 's/^/    /'

echo "=== a pod written the Linux way: command: [/bin/sh, -c, ...]"
k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: script, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-macos-shared
  restartPolicy: Never
  containers:
    - name: script
      image: $img
      command: [/bin/sh, -c]
      args: ["for i in 1 2 3; do echo \"step \$i on \$(sw_vers -productName) \$(sw_vers -productVersion)\"; done"]
EOF
for _ in $(seq 60); do
    case "$(k get pod script -o jsonpath='{.status.phase}')" in Succeeded|Failed) break ;; esac
    sleep 1
done
echo "    script: $(k get pod script -o jsonpath='{.status.phase}')"
k logs script 2>&1 | sed 's/^/    /'

echo "=== does a copied Apple binary run in a root on this node?"
k apply -f "$here/shell-probe.yaml" >/dev/null
for _ in $(seq 60); do
    case "$(k get pod shell-probe -o jsonpath='{.status.phase}')" in Succeeded|Failed) break ;; esac
    sleep 1
done
k logs shell-probe 2>&1 | sed 's/^/    /'

k delete pod web shell-probe script --wait=false >/dev/null 2>&1
