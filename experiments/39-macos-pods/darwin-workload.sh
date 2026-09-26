# Sourced by run-macos-node.sh once the macOS node is Ready, with ferry-darwin
# as its runtime. Ordinary Kubernetes objects, nothing macOS-specific in them
# but the RuntimeClass and a darwin image:
#
#   Deployment web    two replicas of podsrv, both binding 0.0.0.0:8080
#   Job hello         prints what a container sees: its /, processes, interfaces
#   Pod caller        calls one web replica, so the replica reports who called
#
# Then reaches each web pod from this Mac at its own address.

img=example.com/podsrv-darwin:1
here_workload="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
podsrv="$here_workload/build/netpod/bin/podsrv"

echo "--- RuntimeClass ferry-macos-shared (handler ferry-darwin)"
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
apiVersion: batch/v1
kind: Job
metadata: {name: hello, labels: {experiment: "39"}}
spec:
  backoffLimit: 0
  template:
    spec:
      runtimeClassName: ferry-macos-shared
      restartPolicy: Never
      containers: [{name: hello, image: $img, command: [/bin/hello, probe]}]
EOF

t0=$(date +%s)
for _ in $(seq 150); do
    running=$(k get pods -l app=web -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' | grep -c Running)
    job=$(k get job hello -o jsonpath='{.status.succeeded}{.status.failed}')
    [ "$running" = 2 ] && [ -n "$job" ] && break
    sleep 1
done
echo "    two web replicas Running and the Job finished $(( $(date +%s) - t0 )) s after apply"
k get pods -o wide 2>&1 | sed 's/^/    /'

echo "--- kubectl logs job/hello"
k logs job/hello 2>&1 | sed 's/^/    /'
echo "--- kubectl logs, each web replica"
for p in $(k get pods -l app=web -o name); do k logs "$p" 2>&1 | sed "s|^|    ${p#pod/}: |"; done

echo "--- from this Mac, each replica at its own address"
ips=$(k get pods -l app=web -o jsonpath='{range .items[*]}{.status.podIP}{" "}{end}')
for ip in $ips; do printf '    %s:8080  ' "$ip"; "$podsrv" get "$ip" 2>&1; done
node_ip=$(k get node "$name" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
printf '    %s:8080 (the node) ' "$node_ip"; "$podsrv" get "$node_ip" 2>&1

first=${ips%% *}
echo "--- a caller pod, calling $first"
k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: caller, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-macos-shared
  restartPolicy: Never
  containers: [{name: caller, image: $img, args: [get, "$first"]}]
EOF
for _ in $(seq 60); do
    case "$(k get pod caller -o jsonpath='{.status.phase}')" in Succeeded|Failed) break ;; esac
    sleep 1
done
echo "    caller is at $(k get pod caller -o jsonpath='{.status.podIP}'), $(k get pod caller -o jsonpath='{.status.phase}')"
k logs caller 2>&1 | sed 's/^/    caller: /'

echo "--- delete"
t0=$(date +%s)
k delete deploy/web job/hello pod/caller --wait=true --timeout=60s >/dev/null 2>&1
echo "    deleted in $(( $(date +%s) - t0 )) s"
k get pods 2>&1 | sed 's/^/    /'
