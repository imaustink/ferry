#!/usr/bin/env bash
# A macOS machine made the way a Linux one is: kubectl apply a Machine with
# spec.os: darwin, ferry-machined clones the baked golden image, ferry-node
# boots it on the machine network and the pod switch, and the guest's
# ferry-macos-init joins it. Then darwin pods on it, and traffic both ways
# between one of them and a Linux pod VM on the Mac.
#
#   ./run-macos-machine.sh            leaves the machine up
#   KEEP=0 ./run-macos-machine.sh     deletes it at the end
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
state=$("$repo/ferry" profile | awk '$1 == "state" {print $2}')
run=/tmp/ferry-run-${state##*/.ferry-}
export KUBECONFIG="$state/admin.conf"
k() { kubectl "$@"; }
name=mac-0
img=example.com/podsrv-darwin:2

ready() { [ "$(k get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ]; }

echo "=== kubectl apply a Machine, spec.os: darwin"
t0=$(date +%s)
k apply -f "$here/macos-machine.yaml" >/dev/null
for _ in $(seq 180); do ready "$name" && break; sleep 1; done
if ready "$name"; then echo "    $name Ready $(( $(date +%s) - t0 )) s after apply"
else echo "    $name not Ready after 180 s"; fi
k get machines 2>&1 | sed 's/^/    /'
k get nodes -o wide -L ferry.dev/mode 2>&1 | sed 's/^/    /'
k get node "$name" -o jsonpath='    podCIDR: {.spec.podCIDR}  runtime: {.status.nodeInfo.containerRuntimeVersion}  handlers: {.status.runtimeHandlers[*].name}
    taints: {.spec.taints}
' 2>&1
echo "--- ferry-node"
grep -a "$name" "$run/logs/ferry-node.log" | tail -4 | sed 's/^/    /'
ready "$name" || exit 1

echo "=== darwin pods on the machine"
k apply -f - >/dev/null <<EOF
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata: {name: ferry-macos-shared, labels: {experiment: "39"}}
handler: ferry-darwin
scheduling:
  nodeSelector: {ferry.dev/mode: shared-macos}
  tolerations: [{key: ferry.dev/mode, operator: Equal, value: shared-macos, effect: NoSchedule}]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: web, labels: {experiment: "39"}}
spec:
  replicas: 2
  selector: {matchLabels: {app: web}}
  template:
    metadata: {labels: {app: web}}
    spec:
      runtimeClassName: ferry-macos-shared
      containers: [{name: web, image: $img, args: [serve, web]}]
---
apiVersion: v1
kind: Pod
metadata: {name: linux-listener, labels: {experiment: "39", app: linux-listener}}
spec:
  runtimeClassName: ferry-vm
  containers:
    - name: nc
      image: busybox:1.36
      command: [sh, -c, "while true; do echo hello-from-a-linux-pod-vm | nc -l -p 9000; done"]
EOF
t0=$(date +%s)
for _ in $(seq 180); do
    r=$(k get pods -l app=web -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' | grep -c Running)
    l=$(k get pod linux-listener -o jsonpath='{.status.phase}')
    [ "$r" = 2 ] && [ "$l" = Running ] && break
    sleep 1
done
echo "    web x2 and linux-listener Running $(( $(date +%s) - t0 )) s after apply"
k get pods -o wide 2>&1 | sed 's/^/    /'
for p in $(k get pods -l app=web -o name); do k logs "$p" 2>&1 | sed "s|^|    ${p#pod/}: |"; done

web=$(k get pods -l app=web -o jsonpath='{.items[0].status.podIP}')
linux=$(k get pod linux-listener -o jsonpath='{.status.podIP}')

echo "=== a Linux pod VM on the Mac calls a macOS pod ($web:8080)"
k run linux-caller --restart=Never --image=busybox:1.36 \
    --overrides='{"spec":{"runtimeClassName":"ferry-vm"}}' -- sh -c "nc -w 5 $web 8080 </dev/null" >/dev/null
for _ in $(seq 120); do
    case "$(k get pod linux-caller -o jsonpath='{.status.phase}')" in Succeeded|Failed) break ;; esac
    sleep 1
done
echo "    linux-caller at $(k get pod linux-caller -o jsonpath='{.status.podIP}'), $(k get pod linux-caller -o jsonpath='{.status.phase}')"
k logs linux-caller 2>&1 | sed 's/^/    linux-caller: /'

echo "=== a macOS pod calls the Linux pod VM ($linux:9000)"
k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: mac-caller, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-macos-shared
  restartPolicy: Never
  containers: [{name: caller, image: $img, args: [get, "$linux", "9000"]}]
EOF
for _ in $(seq 60); do
    case "$(k get pod mac-caller -o jsonpath='{.status.phase}')" in Succeeded|Failed) break ;; esac
    sleep 1
done
echo "    mac-caller at $(k get pod mac-caller -o jsonpath='{.status.podIP}'), $(k get pod mac-caller -o jsonpath='{.status.phase}')"
k logs mac-caller 2>&1 | sed 's/^/    mac-caller: /'

echo "=== Services, by name"
k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata: {name: web-svc, labels: {experiment: "39"}}
spec: {selector: {app: web}, ports: [{port: 80, targetPort: 8080}]}
---
apiVersion: v1
kind: Service
metadata: {name: linux-svc, labels: {experiment: "39"}}
spec: {selector: {app: linux-listener}, ports: [{port: 9000, targetPort: 9000}]}
EOF
# ferry-darwin reads Services every two seconds.
sleep 5
k get svc web-svc linux-svc 2>&1 | sed 's/^/    /'
k get endpointslices -l 'kubernetes.io/service-name in (web-svc,linux-svc)' 2>&1 | sed 's/^/    /'

wait_done() {
    for _ in $(seq 90); do
        case "$(k get pod "$1" -o jsonpath='{.status.phase}')" in Succeeded|Failed) return ;; esac
        sleep 1
    done
}
web_fqdn=web-svc.default.svc.cluster.local
linux_fqdn=linux-svc.default.svc.cluster.local

echo "--- a Linux pod VM calls web-svc (macOS endpoints) by name"
k run linux-svc-caller --restart=Never --image=busybox:1.36 \
    --overrides='{"spec":{"runtimeClassName":"ferry-vm"}}' -- \
    sh -c "for i in 1 2 3 4; do nc -w 5 $web_fqdn 80 </dev/null; done" >/dev/null
wait_done linux-svc-caller
k logs linux-svc-caller 2>&1 | sed 's/^/    linux-svc-caller: /'

for target in "$web_fqdn 80" "$linux_fqdn 9000"; do
    set -- $target
    pod=mac-svc-caller-${1%%-svc*}
    echo "--- a macOS pod calls $1:$2 by name"
    k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $pod, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-macos-shared
  restartPolicy: Never
  containers: [{name: caller, image: $img, args: [get, "$1", "$2", "4"]}]
EOF
    wait_done "$pod"
    k logs "$pod" 2>&1 | sed "s/^/    $pod: /"
done

if [ -n "${DEBUG:-}" ]; then
    echo "=== the service table, as each container root has it"
    k delete pod services-probe --ignore-not-found >/dev/null 2>&1
    k apply -f "$here/services-probe.yaml" >/dev/null
    wait_done services-probe
    k logs services-probe 2>&1 | sed 's/^/    /'
    k delete pod services-probe --wait=false >/dev/null 2>&1
fi

echo "=== clean up the pods"
k delete deploy/web pod/linux-listener pod/linux-caller pod/mac-caller pod/linux-svc-caller \
    pod/mac-svc-caller-web pod/mac-svc-caller-linux svc/web-svc svc/linux-svc --wait=false >/dev/null 2>&1
if [ "${KEEP:-1}" = 0 ]; then
    t0=$(date +%s)
    k delete machine "$name" --timeout=120s >/dev/null 2>&1
    echo "    machine deleted in $(( $(date +%s) - t0 )) s"
    k get nodes 2>&1 | sed 's/^/    /'
fi
