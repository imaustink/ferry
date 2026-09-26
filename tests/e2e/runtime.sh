#!/usr/bin/env bash
# End to end: the RuntimeClasses, the config file, the default runtime and a
# Machine's durability, on a real cluster.
#
# Brings up a throwaway profile (e2e-runtime, its own ports, state and pod
# network), runs every phase against it, and takes it down again, data and all.
# It needs a built checkout with mode 2 -- `ferry build` and `ferry node-image`
# -- and pulls busybox, registry and buildkit images. About ten minutes.
#
# Not part of tests/run.sh, which never starts a cluster.
#
#   ./tests/e2e/runtime.sh
#   FERRY_E2E_KEEP=1 ./tests/e2e/runtime.sh    # leave the cluster up afterwards
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
ferry="$repo/ferry"

profile="${FERRY_E2E_PROFILE:-e2e-runtime}"
export FERRY_PROFILE="$profile"
unset FERRY_HOME FERRY_RUN FERRY_CONFIG FERRY_DURABILITY FERRY_DEFAULT_RUNTIME FERRY_MACHINE_DURABILITY
home="$HOME/.ferry-$profile"
run="/tmp/ferry-run-$profile"
mac="ferry-mac-$profile"
export KUBECONFIG="$home/admin.conf"
# Written into the state directory this creates, so cleanup only ever removes
# a directory this test made.
owned="$home/.made-by-tests-e2e-runtime"

pass=0; fail=0
bold()  { printf '\033[1m%s\033[0m\n' "$1"; }
ok()    { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()   { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
is() { # description actual expected
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; echo "      got:  '$2'"; echo "      want: '$3'"; fi
}
contains() { # description haystack needle
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1"; echo "      '$(printf '%s' "$2" | tail -c 400)' does not contain '$3'" ;; esac
}
lacks() { # description haystack needle
  case "$2" in *"$3"*) bad "$1"; echo "      contains '$3'" ;; *) ok "$1" ;; esac
}
# The command's output, once it equals the expected value, or its last output
# after the given number of seconds. Scheduling is eventual; a check that reads
# it once is a check that races.
eventually() { # seconds expected command...
  local seconds="$1" want="$2" got; shift 2
  local deadline=$(( $(date +%s) + seconds ))
  while :; do
    got="$("$@" 2>/dev/null)"
    [ "$got" = "$want" ] && { echo "$got"; return 0; }
    [ "$(date +%s)" -ge "$deadline" ] && { echo "$got"; return 1; }
    sleep 1
  done
}
# The same for output that has to contain something rather than equal it.
eventually_has() { # seconds needle command...
  local seconds="$1" needle="$2" got; shift 2
  local deadline=$(( $(date +%s) + seconds ))
  while :; do
    got="$("$@" 2>/dev/null)"
    case "$got" in *"$needle"*) echo "$got"; return 0 ;; esac
    [ "$(date +%s)" -ge "$deadline" ] && { echo "$got"; return 1; }
    sleep 1
  done
}
events_of() { kubectl get events --field-selector "involvedObject.name=$1" -o jsonpath='{.items[*].message}'; }
node_of()   { kubectl get pod "$1" -o jsonpath='{.spec.nodeName}'; }
mode_of()   { kubectl get node "$1" -o jsonpath='{.metadata.labels.ferry\.dev/mode}'; }
taint_of()  { kubectl get node "$1" -o jsonpath='{range .spec.taints[?(@.key=="ferry.dev/mode")]}{.value}{end}'; }
ready_of()  { kubectl get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'; }
phase_of()  { kubectl get pod "$1" -o jsonpath='{.status.phase}'; }
cm_value()  { kubectl -n kube-system get cm ferry-config -o jsonpath="{.data.$1}"; }
etcd_nofsync() { ps -ww -o args= -p "$(cat "$home/etcd.pid")" | grep -c unsafe-no-fsync; }
node_disk_sync() { ps eww -p "$(cat "$run/ferry-node.pid")" | tr ' ' '\n' | sed -n 's/^FERRY_NODE_DISK_SYNC=//p'; }
shared_nodes() { kubectl get nodes -l ferry.dev/mode=shared -o jsonpath='{.items[*].metadata.name}'; }
pod_mode()  { mode_of "$(node_of "$1")"; }
nodeclaim_count() { kubectl get nodeclaims --no-headers 2>/dev/null | wc -l | tr -d ' '; }

# --- preconditions ----------------------------------------------------------
missing=""
for b in kubelet ferry-cri ferry-machined ferry-node ferry-karpenter; do
  [ -x "$repo/bin/$b" ] || missing="$missing bin/$b"
done
[ -d "$repo/node-image/oci" ] || missing="$missing node-image/oci"
for tool in kubectl curl; do command -v "$tool" >/dev/null || missing="$missing $tool"; done
if [ -n "$missing" ]; then
  echo "skipped: needs$missing -- ferry build && ferry node-image"
  exit 0
fi
if [ -e "$home" ] && [ ! -e "$owned" ]; then
  echo "refusing: $home exists and was not made by this test"; exit 2
fi

cleanup() {
  [ "${FERRY_E2E_KEEP:-}" = 1 ] && { echo "left up: FERRY_PROFILE=$profile $ferry status"; return; }
  "$ferry" down --purge >/dev/null 2>&1
  [ -e "$owned" ] && rm -rf "$home"
  rm -rf "$run"
}
trap cleanup EXIT
# Anything left from an interrupted run of this test.
[ -e "$owned" ] && { "$ferry" down --purge >/dev/null 2>&1; rm -rf "$home" "$run"; }

# --- A: a cluster from before the config file ---------------------------------
bold "A: a cluster with the old marker files comes up and is migrated"
mkdir -p "$home"; : > "$owned"
echo relaxed > "$home/durability"; : > "$home/machines-enabled"
out="$("$ferry" up 2>&1)"; rc=$?
is "ferry up succeeds" "$rc" 0
[ "$rc" = 0 ] || { echo "$out" | tail -20; exit 1; }
contains "  names its config file" "$out" "config $home/config.yaml"
contains "  and warns it is process-crash, from the old 'relaxed'" "$out" "durability: process-crash"
is "  durability moved into the file, in its new name" "$("$ferry" config get durability)" process-crash
is "  machines moved into the file" "$(sed -n 's/^machines: //p' "$home/config.yaml")" true
is "  both markers removed" "$(ls "$home/durability" "$home/machines-enabled" 2>/dev/null | wc -l | tr -d ' ')" 0
is "  etcd without fsync" "$(etcd_nofsync)" 1
is "  machine disks without a barrier" "$(node_disk_sync)" none
out="$("$ferry" up --durability power-loss 2>&1)"; rc=$?
is "a different durability on a running cluster is refused" "$rc" 1
contains "  saying what it is up with" "$out" "ferry is up with durability process-crash"

# --- B: ferry init at a terminal ---------------------------------------------
bold "B: ferry init writes the config, asked at a terminal"
"$ferry" down >/dev/null 2>&1
if command -v expect >/dev/null 2>&1; then
  out="$(expect -c "
    set timeout 20
    spawn env FERRY_PROFILE=$profile $ferry init --force
    expect -exact {choice: };                                   send \"\r\"
    expect -exact {Run machines as well};                       send \"\r\"
    expect -exact {Where should a pod that names no RuntimeClass run?}
    expect -exact {choice: };                                   send \"\r\"
    expect -exact {from a script if it were lost?};             send \"\r\"
    expect eof" 2>&1)"
  contains "every question asked, mode 2 included" "$out" "Where should a pod that names no RuntimeClass run?"
else
  echo "  (expect not installed: answering from flags)"
  "$ferry" init --force --purpose dev --yes </dev/null >/dev/null 2>&1
fi
is "  purpose dev" "$("$ferry" config get purpose)" dev
is "  durability power-loss" "$("$ferry" config get durability)" power-loss
is "  machines on" "$("$ferry" config get machines)" true
is "  defaultRuntime ferry-vm" "$("$ferry" config get defaultRuntime)" ferry-vm

# --- C: a ferry-vm default ----------------------------------------------------
bold "C: defaultRuntime ferry-vm"
out="$("$ferry" up 2>&1)"; rc=$?
is "ferry up succeeds" "$rc" 0
[ "$rc" = 0 ] || { echo "$out" | tail -20; exit 1; }
contains "  says what a pod that names nothing runs as" "$out" "pods that name no RuntimeClass run as ferry-vm"
lacks "  and does not warn about durability" "$out" "durability: process-crash"
is "  etcd fsyncs again" "$(etcd_nofsync)" 0
is "  machine disks fsync again" "$(node_disk_sync)" fsync
is "ferry-vm class, handler ferry-vm" "$(kubectl get runtimeclass ferry-vm -o jsonpath='{.handler}')" ferry-vm
is "  with the pod VM's overhead" "$(kubectl get runtimeclass ferry-vm -o jsonpath='{.overhead.podFixed.memory}')" 133Mi
is "ferry-shared class, handler runc" "$(kubectl get runtimeclass ferry-shared -o jsonpath='{.handler}')" runc
is "ConfigMap: defaultRuntime" "$(cm_value defaultRuntime)" ferry-vm
is "ConfigMap: durability" "$(cm_value durability)" power-loss
is "NodePool carries the machines' taint" "$(kubectl get nodepool default -o jsonpath='{.spec.template.spec.taints[0].value}')" shared
contains "the Mac advertises the ferry-vm handler" "$(kubectl get node "$mac" -o jsonpath='{.status.runtimeHandlers[*].name}')" ferry-vm
is "the Mac is untainted" "$(taint_of "$mac")" ""

kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: c-plain}
spec:
  containers: [{name: c, image: busybox:1.36, command: [sleep, "3600"]}]
---
apiVersion: v1
kind: Pod
metadata: {name: c-vm}
spec:
  runtimeClassName: ferry-vm
  containers: [{name: c, image: busybox:1.36, command: [sleep, "3600"]}]
---
apiVersion: v1
kind: Pod
metadata: {name: c-shared}
spec:
  runtimeClassName: ferry-shared
  containers: [{name: c, image: busybox:1.36, command: [sleep, "3600"]}]
---
apiVersion: v1
kind: Pod
metadata: {name: c-selector-only}
spec:
  nodeSelector: {ferry.dev/mode: shared}
  containers: [{name: c, image: busybox:1.36, command: [sleep, "3600"]}]
---
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata: {name: e2e-runc-anywhere}
handler: runc
---
apiVersion: v1
kind: Pod
metadata: {name: c-wrong-handler}
spec:
  runtimeClassName: e2e-runc-anywhere
  nodeName: $mac
  containers: [{name: c, image: busybox:1.36, command: [sleep, "3600"]}]
EOF
kubectl create deployment c-spread --image=busybox:1.36 --replicas=6 -- sleep 3600 >/dev/null
kubectl wait --for=condition=Ready pod/c-plain pod/c-vm --timeout=120s >/dev/null
is "a pod naming no class runs on the Mac" "$(node_of c-plain)" "$mac"
is "a ferry-vm pod runs on the Mac" "$(node_of c-vm)" "$mac"
is "  charged the overhead" "$(kubectl get pod c-vm -o jsonpath='{.spec.overhead.memory}')" 133Mi
is "  which a pod naming no class is not" "$(kubectl get pod c-plain -o jsonpath='{.spec.overhead.memory}')" ""
kubectl wait --for=condition=Ready pod/c-shared --timeout=300s >/dev/null
shared_node="$(node_of c-shared)"
is "a ferry-shared pod runs on a machine Karpenter made" "$(mode_of "$shared_node")" shared
is "  which registered with the machines' taint" "$(taint_of "$shared_node")" shared
kubectl rollout status deploy/c-spread --timeout=120s >/dev/null
is "six unpinned replicas, all on the Mac though a machine is there" \
  "$(kubectl get pods -l app=c-spread -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u)" "$mac"
contains "a handler ferry-cri does not serve is refused" \
  "$(eventually_has 60 'has no runtime handler "runc"' events_of c-wrong-handler)" 'has no runtime handler "runc"'
sleep 20
is "a pod picking machines by nodeSelector alone stays Pending" "$(phase_of c-selector-only)" Pending
contains "  on the taint" "$(events_of c-selector-only)" "untolerated taint"
is "  and Karpenter makes no machine for it" "$(nodeclaim_count)" 1
kubectl delete pod c-selector-only c-wrong-handler --wait=false >/dev/null
kubectl delete runtimeclass e2e-runc-anywhere >/dev/null
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: ferry.dev/v1alpha1
kind: Machine
metadata: {name: hand-0}
spec: {cpus: 2, memory: 2Gi}
EOF
is "a Machine written by hand becomes Ready" "$(eventually 180 True ready_of hand-0)" True
is "  registered with the default's taint" "$(taint_of hand-0)" shared
is "machine CoreDNS runs on every tainted machine" \
  "$(eventually 120 Running sh -c "kubectl -n kube-system get pods -l k8s-app=kube-dns-machines -o jsonpath='{range .items[*]}{.status.phase}{\"\n\"}{end}' | sort -u")" Running
# A DaemonSet meant for every node skips the tainted kind unless it tolerates
# the taint (docs/RUNTIMES.md, "DaemonSets meant for every node").
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata: {name: c-ds-plain}
spec:
  selector: {matchLabels: {app: c-ds-plain}}
  template:
    metadata: {labels: {app: c-ds-plain}}
    spec:
      containers: [{name: c, image: busybox:1.36, command: [sleep, "3600"]}]
---
apiVersion: apps/v1
kind: DaemonSet
metadata: {name: c-ds-everywhere}
spec:
  selector: {matchLabels: {app: c-ds-everywhere}}
  template:
    metadata: {labels: {app: c-ds-everywhere}}
    spec:
      tolerations:
        - {key: ferry.dev/mode, operator: Exists, effect: NoSchedule}
      containers: [{name: c, image: busybox:1.36, command: [sleep, "3600"]}]
EOF
ds_desired() { kubectl get ds "$1" -o jsonpath='{.status.desiredNumberScheduled}'; }
ready_nodes="$(kubectl get nodes --no-headers | awk '$2 == "Ready"' | wc -l | tr -d ' ')"
is "a DaemonSet with no toleration runs only on the untainted Mac" "$(eventually 60 1 ds_desired c-ds-plain)" 1
is "  one that tolerates ferry.dev/mode runs on every node" "$(eventually 60 "$ready_nodes" ds_desired c-ds-everywhere)" "$ready_nodes"
kubectl delete ds c-ds-plain c-ds-everywhere --wait=false >/dev/null

# --- D: a Machine's durability ------------------------------------------------
bold "D: a Machine's durability is its disk's barrier"
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: ferry.dev/v1alpha1
kind: Machine
metadata: {name: d-full}
spec: {cpus: 2, memory: 2Gi, durability: power-loss}
---
apiVersion: ferry.dev/v1alpha1
kind: Machine
metadata: {name: d-none}
spec: {cpus: 2, memory: 2Gi, durability: process-crash}
EOF
out="$(kubectl apply -f - 2>&1 <<'EOF'
apiVersion: ferry.dev/v1alpha1
kind: Machine
metadata: {name: d-bad}
spec: {cpus: 2, memory: 2Gi, durability: relaxed}
EOF
)"
contains "a cluster-level word is not a machine level: refused" "$out" "Unsupported value"
for m in d-full d-none; do is "$m Ready" "$(eventually 180 True ready_of $m)" True; done
is "d-full asks ferry-node for the full barrier" "$(grep -o '"diskSync": "[a-z]*"' "$run/machines/d-full.json")" '"diskSync": "full"'
is "d-none asks for none" "$(grep -o '"diskSync": "[a-z]*"' "$run/machines/d-none.json")" '"diskSync": "none"'
is "hand-0 leaves it to the cluster's default" "$(grep -c diskSync "$run/machines/hand-0.json")" 0
is "kubectl shows it in -o wide" "$(kubectl get machine d-full -o wide --no-headers | awk '{print $7}')" power-loss
for m in d-full hand-0 d-none; do
  sed "s/__NODE__/$m/" <<'EOF' | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: sync-__NODE__}
spec:
  runtimeClassName: ferry-shared
  nodeName: __NODE__
  restartPolicy: Never
  containers:
    - name: c
      image: busybox:1.36
      command:
        - sh
        - -c
        - time sh -c 'i=0; while [ $i -lt 300 ]; do echo x >> /tmp/f; sync; i=$((i+1)); done' 2>&1 | grep real
EOF
done
sync_ms() { # machine: busybox's "real 0m 1.23s", in ms
  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/sync-$1" --timeout=240s >/dev/null
  kubectl logs "sync-$1" | awk '{ split($2, m, "m"); s = $3; sub(/s$/, "", s); printf "%d", (m[1] * 60 + s) * 1000 }'
}
full="$(sync_ms d-full)"; fsync="$(sync_ms hand-0)"; none="$(sync_ms d-none)"
echo "  300 write+sync rounds: power-loss ${full}ms, os-crash ${fsync}ms, process-crash ${none}ms"
# Only the full barrier is big enough to see this way. An fsync(2) on this
# SSD is ~0.03ms against ~4ms for F_FULLFSYNC (README), so across 300 rounds
# os-crash and process-crash differ by less than the loop's own noise: two
# runs gave 790/120 and 330/460. What reaches ferry-node for those two is
# checked above in the spec files, and which barrier wins is DiskSyncTests.
slowest_other=$fsync; [ "${none:-0}" -gt "${slowest_other:-0}" ] && slowest_other=$none
if [ "${full:-0}" -gt $(( 2 * ${slowest_other:-0} )) ]; then r=yes; else r="$full vs $fsync/$none"; fi
is "power-loss pays the full barrier: over twice os-crash and process-crash" "$r" yes
kubectl delete machine d-full d-none hand-0 --wait=false >/dev/null

# --- E: the builder and the registry addon --------------------------------------
bold "E: the builder and the registry addon stay VMs on the Mac"
kubectl delete runtimeclass ferry-vm >/dev/null
ctx="$(mktemp -d)"
printf 'FROM busybox:1.36\nRUN echo built-by-ferry > /hello\nCMD ["cat", "/hello"]\n' > "$ctx/Dockerfile"
out="$("$ferry" image build -t e2e-runtime:1 "$ctx" 2>&1)"; rc=$?
is "ferry image build, on a cluster missing the ferry-vm class" "$rc" 0
[ "$rc" = 0 ] || echo "$out" | tail -15
is "  puts the class back" "$(kubectl get runtimeclass ferry-vm -o jsonpath='{.handler}')" ferry-vm
is "  runs the builder as ferry-vm" "$(kubectl -n kube-system get pod ferry-builder -o jsonpath='{.spec.runtimeClassName}')" ferry-vm
is "  on the Mac" "$(kubectl -n kube-system get pod ferry-builder -o jsonpath='{.spec.nodeName}')" "$mac"
kubectl run e2e-built --restart=Never --image=e2e-runtime:1 --image-pull-policy=Never >/dev/null
is "  and what it built runs" "$(eventually 120 Succeeded phase_of e2e-built)" Succeeded
is "  saying what it was built to" "$(kubectl logs e2e-built)" built-by-ferry
"$ferry" image build --stop >/dev/null 2>&1
out="$("$ferry" addons enable registry 2>&1)"; rc=$?
is "the registry addon enables" "$rc" 0
[ "$rc" = 0 ] || echo "$out" | tail -15
is "  as ferry-vm" "$(kubectl -n registry get pods -l app=registry -o jsonpath='{.items[0].spec.runtimeClassName}')" ferry-vm
is "  on the Mac" "$(kubectl -n registry get pods -l app=registry -o jsonpath='{.items[0].spec.nodeName}')" "$mac"
is "  and localhost:5001 answers" "$(curl -fsS --max-time 5 -o /dev/null -w '%{http_code}' http://localhost:5001/v2/)" 200

# --- F: switched to ferry-shared on a running cluster --------------------------
bold "F: defaultRuntime ferry-shared, set on the running cluster"
claims_before="$(kubectl get nodeclaims -o jsonpath='{.items[*].metadata.name}')"
running_before="$(kubectl get pods -l app=c-spread --field-selector=status.phase=Running --no-headers | wc -l | tr -d ' ')"
out="$("$ferry" config set defaultRuntime ferry-shared 2>&1)"
contains "ferry config set applies it at once" "$out" "applied to the running cluster"
is "  the Mac is tainted" "$(taint_of "$mac")" vm-per-pod
for m in $(shared_nodes); do is "  $m is untainted" "$(eventually 10 "" taint_of "$m")" ""; done
is "  the NodePool's taint is gone" "$(kubectl get nodepool default -o jsonpath='{.spec.template.spec.taints}')" ""
is "  the ConfigMap follows" "$(cm_value defaultRuntime)" ferry-shared
sleep 5
is "pods already on the Mac keep running (NoSchedule)" \
  "$(kubectl get pods -l app=c-spread --field-selector=status.phase=Running --no-headers | wc -l | tr -d ' ')" "$running_before"
kubectl run f-plain --image=busybox:1.36 -- sleep 3600 >/dev/null
kubectl wait --for=condition=Ready pod/f-plain --timeout=300s >/dev/null
is "a new pod naming no class goes to a machine" "$(pod_mode f-plain)" shared
kubectl -n registry delete pod -l app=registry --wait=true >/dev/null
kubectl -n registry rollout status deploy/registry --timeout=120s >/dev/null
is "the registry, recreated, is back on the Mac" "$(kubectl -n registry get pods -l app=registry -o jsonpath='{.items[0].spec.nodeName}')" "$mac"
is "  and localhost:5001 answers" "$(eventually 30 200 curl -fsS --max-time 5 -o /dev/null -w '%{http_code}' http://localhost:5001/v2/)" 200
kubectl -n kube-system delete pod -l k8s-app=kube-dns --wait=true >/dev/null
kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=kube-dns --timeout=120s >/dev/null
is "mode 1 CoreDNS, recreated, is back on the Mac" "$(kubectl -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{.items[0].spec.nodeName}')" "$mac"
kubectl run f-dns-vm --restart=Never --image=busybox:1.36 --overrides='{"spec":{"runtimeClassName":"ferry-vm"}}' \
  -- nslookup kubernetes.default.svc.cluster.local >/dev/null
kubectl run f-dns-shared --restart=Never --image=busybox:1.36 -- nslookup kubernetes.default.svc.cluster.local >/dev/null
is "a VM on the Mac resolves the kubernetes Service" "$(eventually 120 Succeeded phase_of f-dns-vm)" Succeeded
is "  it ran on the Mac" "$(node_of f-dns-vm)" "$mac"
is "a container on a machine resolves it" "$(eventually 120 Succeeded phase_of f-dns-shared)" Succeeded
is "  it ran on a machine" "$(pod_mode f-dns-shared)" shared
ctx="$(mktemp -d)"; printf 'FROM busybox:1.36\nRUN true\n' > "$ctx/Dockerfile"
"$ferry" image build -t e2e-runtime:2 "$ctx" >/dev/null 2>&1
is "ferry image build works with the Mac tainted" "$?" 0
"$ferry" image build --stop >/dev/null 2>&1
drift_gone() { local c; for c in $claims_before; do kubectl get nodeclaim "$c" >/dev/null 2>&1 && { echo no; return; }; done; echo yes; }
is "Karpenter replaces the machine it made under the old default" "$(eventually 120 yes drift_gone)" yes
kubectl taint node "$mac" ferry.dev/mode:NoSchedule- >/dev/null
is "ferry-machined puts back a taint removed by hand" "$(eventually 15 vm-per-pod taint_of "$mac")" vm-per-pod
out="$("$ferry" node add e2e-n2 2>&1)"; rc=$?
is "ferry node add, after the switch" "$rc" 0
[ "$rc" = 0 ] || echo "$out" | tail -10
is "  the new node is tainted with no ferry up" "$(eventually 60 vm-per-pod taint_of e2e-n2)" vm-per-pod
"$ferry" node rm e2e-n2 >/dev/null 2>&1

# --- G: ferry-shared needs machines ---------------------------------------------
bold "G: ferry-shared without machines, and none"
out="$("$ferry" machines disable 2>&1)"
contains "machines disable says ferry-shared now waits" "$out" "defaultRuntime ferry-shared needs machines"
is "  the Mac is untainted, so pods still have somewhere to go" "$(taint_of "$mac")" ""
is "  the ConfigMap says none is in effect" "$(cm_value defaultRuntime)" none
is "  the file keeps what was asked for" "$("$ferry" config get defaultRuntime)" ferry-shared
contains "  and ferry config explains the difference" "$("$ferry" config)" "ferry-shared waits for machines"
kubectl run g-plain --image=busybox:1.36 -- sleep 3600 >/dev/null
kubectl wait --for=condition=Ready pod/g-plain --timeout=120s >/dev/null
is "  a new pod runs on the Mac" "$(node_of g-plain)" "$mac"
"$ferry" machines enable >/dev/null 2>&1
is "machines enable: the Mac's taint is back" "$(taint_of "$mac")" vm-per-pod
is "  and the ConfigMap says ferry-shared" "$(cm_value defaultRuntime)" ferry-shared
"$ferry" config set defaultRuntime none >/dev/null 2>&1
is "defaultRuntime none: the Mac is untainted" "$(taint_of "$mac")" ""
for m in $(shared_nodes); do is "  $m is untainted" "$(eventually 10 "" taint_of "$m")" ""; done
is "  the NodePool is untainted" "$(kubectl get nodepool default -o jsonpath='{.spec.template.spec.taints}')" ""
contains "  ferry status says there is no default" "$("$ferry" status)" "no default"

# --- H: purge keeps the config; --disposable ------------------------------------
bold "H: --purge keeps the config; --disposable and --fast"
out="$("$ferry" down --purge 2>&1)"
contains "down --purge says the config is kept" "$out" "config.yaml is kept"
is "  and it is" "$("$ferry" config get purpose)" dev
is "  the machine disks are gone" "$(ls "$home/machined" 2>/dev/null | wc -l | tr -d ' ')" 0
out="$("$ferry" up --disposable 2>&1)"; rc=$?
is "up --disposable" "$rc" 0
[ "$rc" = 0 ] || { echo "$out" | tail -20; exit 1; }
contains "  warns it is process-crash" "$out" "durability: process-crash"
is "  and remembers it" "$("$ferry" config get durability)" process-crash
is "  etcd without fsync" "$(etcd_nofsync)" 1
contains "  machines back, from the kept config" "$out" "machines reconciling"
is "  both classes back after the purge" "$(kubectl get runtimeclass -o name | sort | tr '\n' ' ')" \
  "runtimeclass.node.k8s.io/ferry-shared runtimeclass.node.k8s.io/ferry-vm "
is "  and the default as the file has it" "$(cm_value defaultRuntime)" none
out="$("$ferry" up --fast 2>&1)"; rc=$?
is "up --fast on the running process-crash cluster" "$rc" 0
contains "  says it is --disposable now" "$out" "--fast is now --disposable"
out="$("$ferry" up --durability full 2>&1)"; rc=$?
is "the old name full, against it, is refused" "$rc" 1
contains "  in the new words" "$out" "ferry is up with durability process-crash"

echo
if [ "$fail" -eq 0 ]; then bold "$pass passed"; else bold "$pass passed, $fail failed"; exit 1; fi
