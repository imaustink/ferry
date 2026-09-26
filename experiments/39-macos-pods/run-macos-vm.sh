#!/usr/bin/env bash
# Mode 1 for macOS: a pod that is a macOS VM of its own. Nothing is declared.
#
#   1. a Job of two pods, runtimeClassName: ferry-macos-vm
#                               -> two macOS machines, one pod each, each pod
#                                  root on a kernel no other pod shares
#   2. a third pod              -> Pending: the Mac's two macOS guest slots are
#                                  both a pod's VM, and a VM a pod has had
#                                  takes no other
#   3. the Job finishes         -> its machines go, and the third pod gets a
#                                  fresh VM rather than one the Job had root in
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
state=$("$here/../../ferry" profile | awk '$1 == "state" {print $2}')
export KUBECONFIG="$state/admin.conf"
k() { kubectl "$@"; }
img=example.com/podsrv-darwin:3
t0=$(date +%s)
el() { echo "$(( $(date +%s) - t0 )) s"; }
show() {
    k get nodeclaims -o custom-columns=CLAIM:.metadata.name,TYPE:.metadata.labels.node\\.kubernetes\\.io/instance-type,PODS:.status.capacity.pods 2>&1 | sed 's/^/    /'
    k get nodes -L ferry.dev/mode 2>&1 | sed 's/^/    /'
    k get pods -l exp=macvm -o wide 2>&1 | sed 's/^/    /'
}
running() { k get pods -l job-name=macvm -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' | grep -c Running; }

k delete machine --all --timeout=120s >/dev/null 2>&1
k delete job macvm --ignore-not-found --wait=true >/dev/null 2>&1
k delete pod macvm-third --ignore-not-found --wait=true >/dev/null 2>&1
# As manifests/runtimeclasses.yaml has them; applied here too so this runs
# against a cluster started before they shipped.
k apply -f - >/dev/null <<EOF
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata: {name: ferry-macos-vm, labels: {app.kubernetes.io/managed-by: ferry}}
handler: ferry-darwin
scheduling:
  nodeSelector: {ferry.dev/mode: macos-vm}
  tolerations: [{key: ferry.dev/mode, operator: Equal, value: macos-vm, effect: NoSchedule}]
---
apiVersion: batch/v1
kind: Job
metadata: {name: macvm, labels: {experiment: "39"}}
spec:
  parallelism: 2
  completions: 2
  backoffLimit: 0
  template:
    metadata: {labels: {exp: macvm}}
    spec:
      runtimeClassName: ferry-macos-vm
      restartPolicy: Never
      containers:
        - name: job
          image: $img
          resources: {requests: {cpu: 500m, memory: 512Mi}}
          command: [/bin/sh, -c]
          args:
            - |
              echo "uid \$(id -u), kernel boot session \$(sysctl -n kern.bootsessionuuid)"
              echo "booted \$(sysctl -n kern.boottime | sed 's/.*} //')"
              m=\$(sysctl -n kern.maxfilesperproc)
              sysctl -w kern.maxfilesperproc=\$m >/dev/null && echo "sysctl -w: allowed" || echo "sysctl -w: refused"
              renice -n -5 -p \$\$ >/dev/null && echo "renice -5: allowed" || echo "renice -5: refused"
              sleep 40
EOF
echo "=== 1. a Job of two macOS VM pods: kubectl apply at 0 s"
for _ in $(seq 300); do [ "$(running)" = 2 ] && break; sleep 2; done
echo "    both Running after $(el)"
show

echo "=== 2. a third ferry-macos-vm pod"
k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: macvm-third, labels: {experiment: "39", exp: macvm}}
spec:
  runtimeClassName: ferry-macos-vm
  restartPolicy: Never
  containers: [{name: c, image: $img, command: [/bin/sh, -c, 'echo "uid \$(id -u), kernel boot session \$(sysctl -n kern.bootsessionuuid)"; ls /private/tmp']}]
EOF
sleep 15
echo "    macvm-third: $(k get pod macvm-third -o jsonpath='{.status.phase}') on '$(k get pod macvm-third -o jsonpath='{.spec.nodeName}')'"
k get events --field-selector involvedObject.name=macvm-third -o custom-columns=REASON:.reason,MESSAGE:.message 2>&1 \
    | tail -3 | cut -c1-220 | sed 's/^/    /'
k get nodes -o custom-columns=NODE:.metadata.name,TAINTS:.spec.taints[*].key 2>&1 | sed 's/^/    /'

k wait --for=condition=complete job/macvm --timeout=180s >/dev/null
echo "=== what each pod saw"
for p in $(k get pods -l job-name=macvm -o name); do
    echo "--- $p on $(k get "$p" -o jsonpath='{.spec.nodeName}')"
    k logs "$p" 2>&1 | sed 's/^/    /'
done

echo "=== 3. the Job is done: its machines go, and the third pod gets a fresh one"
t0=$(date +%s)
job_nodes=$(k get pods -l job-name=macvm -o jsonpath='{.items[*].spec.nodeName}')
k delete job macvm --wait=true >/dev/null 2>&1
for _ in $(seq 300); do
    case "$(k get pod macvm-third -o jsonpath='{.status.phase}')" in Succeeded|Failed) break ;; esac
    sleep 2
done
third=$(k get pod macvm-third -o jsonpath='{.spec.nodeName}')
echo "    macvm-third: $(k get pod macvm-third -o jsonpath='{.status.phase}') after $(el) on $third (the Job's were: $job_nodes)"
k logs macvm-third 2>&1 | sed 's/^/    /'
case " $job_nodes " in *" $third "*|"  ") fresh=no ;; *) fresh=yes ;; esac
[ -n "$third" ] || fresh=no
echo "    third pod on a fresh VM: $fresh"
k delete pod macvm-third --wait=true >/dev/null 2>&1
for _ in $(seq 300); do [ "$(k get machines --no-headers 2>/dev/null | wc -l | tr -d ' ')" = 0 ] && break; sleep 2; done
echo "    no machines after $(el)"
show
