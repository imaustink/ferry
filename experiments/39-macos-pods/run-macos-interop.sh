#!/usr/bin/env bash
# All three kinds of pod in one cluster: Linux pod VMs on the Mac, Linux
# containers on a Linux machine, macOS processes on a macOS machine. The
# earlier tests only ever had the first and the last; this adds a Linux
# machine and sends TCP and UDP between it and the macOS machine, by address
# and by Service name.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
state=$("$here/../../ferry" profile | awk '$1 == "state" {print $2}')
export KUBECONFIG="$state/admin.conf"
k() { kubectl "$@"; }
img=example.com/podsrv-darwin:3
wait_phase() {
    for _ in $(seq 90); do
        case "$(k get pod "$1" -o jsonpath='{.status.phase}')" in Succeeded|Failed) return ;; esac
        sleep 1
    done
}

echo "=== machines: mac-0 (darwin) and worker-0 (linux)"
k apply -f "$here/macos-machine.yaml" >/dev/null
k apply -f - >/dev/null <<EOF
apiVersion: ferry.dev/v1alpha1
kind: Machine
metadata: {name: worker-0, labels: {experiment: "39"}}
spec: {cpus: 2, memory: 2Gi}
EOF
for n in mac-0 worker-0; do
    for _ in $(seq 180); do k get node "$n" >/dev/null 2>&1 && break; sleep 1; done
    k wait --for=condition=Ready "node/$n" --timeout=180s >/dev/null || { echo "$n not Ready"; exit 1; }
done
k get nodes -o wide -L ferry.dev/mode 2>&1 | sed 's/^/    /'

k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: mac-web, labels: {experiment: "39", app: mac-web}}
spec:
  runtimeClassName: ferry-macos-shared
  containers: [{name: web, image: $img, args: [serve, mac-web]}]
---
apiVersion: v1
kind: Pod
metadata: {name: lm, labels: {experiment: "39", app: lm}}
spec:
  runtimeClassName: ferry-shared
  containers:
    - name: tcp
      image: busybox:1.36
      command: [sh, -c, "while true; do echo hello-from-a-linux-machine-pod | nc -l -p 9000; done"]
    - name: udp
      image: busybox:1.36
      command: [udpsvd, "0", "9001", sh, -c, "echo udp-hello-from-a-linux-machine-pod"]
---
apiVersion: v1
kind: Service
metadata: {name: mac-web-svc, labels: {experiment: "39"}}
spec: {selector: {app: mac-web}, ports: [{port: 80, targetPort: 8080}]}
---
apiVersion: v1
kind: Service
metadata: {name: lm-svc, labels: {experiment: "39"}}
spec:
  selector: {app: lm}
  ports:
    - {name: tcp, port: 9000, protocol: TCP}
    - {name: udp, port: 9001, protocol: UDP}
EOF
k wait --for=condition=Ready pod/mac-web pod/lm --timeout=180s >/dev/null
sleep 5  # ferry-darwin reads Services every two seconds
k get pods -o wide 2>&1 | sed 's/^/    /'
mac=$(k get pod mac-web -o jsonpath='{.status.podIP}')
lm=$(k get pod lm -o jsonpath='{.status.podIP}')

echo "=== a Linux machine's pod calls the macOS pod"
k exec lm -c tcp -- sh -c "nc -w 5 $mac 8080 </dev/null; nc -w 5 mac-web-svc.default.svc.cluster.local 80 </dev/null" 2>&1 | sed 's/^/    /'

echo "=== the macOS pod calls the Linux machine's pod"
k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: mac-calls-lm, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-macos-shared
  restartPolicy: Never
  containers:
    - name: c
      image: $img
      command: [/bin/sh, -c]
      args:
        - |
          echo "by address, tcp:"; /bin/podsrv get $lm 9000
          echo "by name, tcp:";    /bin/podsrv get lm-svc.default.svc.cluster.local 9000
          echo "by name, udp:";    /bin/podsrv udp lm-svc.default.svc.cluster.local 9001 hello
          echo "cluster DNS now:"; cat /etc/resolver/cluster.local 2>/dev/null || echo "(not visible in the root)"
EOF
wait_phase mac-calls-lm
k logs mac-calls-lm 2>&1 | sed 's/^/    /'
echo "--- the resolver ferry-darwin wrote"
grep -a "resolves through" "$state/machined/mac-0.macvm.logs/runtime.log" | tail -2 | sed 's/^/    /'

[ "${KEEP:-0}" = 1 ] || k delete pod mac-web lm mac-calls-lm --wait=false >/dev/null 2>&1
[ "${KEEP:-0}" = 1 ] || k delete svc mac-web-svc lm-svc >/dev/null 2>&1
if [ "${KEEP:-0}" != 1 ]; then k delete machine worker-0 mac-0 --timeout=120s >/dev/null 2>&1; fi
