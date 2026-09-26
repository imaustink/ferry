#!/usr/bin/env bash
# A macOS guest as a node of this checkout's ferry cluster.
#
# Boots a pod from a golden image, shares ferry's darwin kubelet and a runtime
# into it, and joins it with a bootstrap token the way ferry-machined joins a
# Linux machine. Then reports what the cluster sees and schedules a pod onto it
# with a ferry-macos-shared RuntimeClass.
#
#   ./run-macos-node.sh [golden]                  runtime: experiment 01's fakecri
#   RUNTIME=path ARGS='...' ./run-macos-node.sh   another CRI, and its arguments
#   SHARE_EXTRA='files...'                        more files for the share
#   WORKLOAD=script                               sourced once the node is Ready,
#                                                 in place of the hello pod
set -euo pipefail
trap 'echo "run-macos-node.sh: line $LINENO failed: $BASH_COMMAND" >&2' ERR
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
golden="${1:-$here/.cache/golden-sipoff}"
state=$("$repo/ferry" profile | awk '$1 == "state" {print $2}')
export KUBECONFIG="$state/admin.conf"
name=macos-node-0
k() { kubectl "$@"; }

# The address a machine reaches the API server by: the one it advertises,
# which its serving certificate covers. admin.conf says 127.0.0.1.
advertise=$("$repo/ferry" profile | awk '$1 == "api" {print $3}')
host=${advertise#https://}; host=${host%:*}
openssl x509 -in "$state/pki/apiserver.crt" -noout -ext subjectAltName | grep -q "$host" \
    || { echo "the API server's certificate does not cover $host"; exit 1; }

share="$here/build/node-share"
rm -rf "$share"; mkdir -p "$share"
cp -c "$(readlink -f "$repo/bin/kubelet")" "$share/kubelet"
cp -c "${RUNTIME:-$repo/bin/fakecri}" "$share/runtime"
echo "${ARGS:--endpoint /private/var/ferry/node/cri.sock -log-repeats 1}" > "$share/runtime-args"
for f in ${SHARE_EXTRA:-}; do cp -c "$f" "$share/"; done
cp "$state/pki/ca.crt" "$share/ca.crt"
echo "$name" > "$share/node-name"
echo "ferry.dev/mode=shared-macos" > "$share/node-labels"
echo "ferry.dev/mode=shared-macos:NoSchedule" > "$share/node-taints"

# A bootstrap token in the group ferry-machined's RBAC already trusts.
id=$(openssl rand -hex 3)
secret=$(openssl rand -hex 8)
k -n kube-system create secret generic "bootstrap-token-$id" --type=bootstrap.kubernetes.io/token \
    --from-literal=token-id="$id" --from-literal=token-secret="$secret" \
    --from-literal=usage-bootstrap-authentication=true --from-literal=usage-bootstrap-signing=true \
    --from-literal=auth-extra-groups=system:bootstrappers:ferry:default-node-token \
    --from-literal=description="experiment 39, $name" >/dev/null
for b in "ferry:node-bootstrapper system:node-bootstrapper group=system:bootstrappers:ferry:default-node-token" \
         "ferry:node-autoapprove system:certificates.k8s.io:certificatesigningrequests:nodeclient group=system:bootstrappers:ferry:default-node-token" \
         "ferry:node-autoapprove-renew system:certificates.k8s.io:certificatesigningrequests:selfnodeclient group=system:nodes"; do
    set -- $b
    k create clusterrolebinding "$1" --clusterrole="$2" --"$3" >/dev/null 2>&1 || true
done

cat > "$share/bootstrap.conf" <<EOF
apiVersion: v1
kind: Config
clusters: [{name: ferry, cluster: {server: "$advertise", certificate-authority: /private/var/ferry/share/ca.crt}}]
users: [{name: bootstrap, user: {token: "$id.$secret"}}]
contexts: [{name: bootstrap, context: {cluster: ferry, user: bootstrap}}]
current-context: bootstrap
EOF

# The Mac's own kubelet config, moved to the guest's paths and default ports.
sed -e "s|^port: .*|port: 10250|" -e "s|^healthzPort: .*|healthzPort: 10248|" \
    -e "s|/tmp/ferry-run-[a-z-]*|/private/var/ferry/node|g" \
    -e "s|unix:///tmp/ferry-cri[a-z-]*\.sock|unix:///private/var/ferry/node/cri.sock|" \
    -e "s|clientCAFile: .*}|clientCAFile: /private/var/ferry/share/ca.crt}|" \
    "/tmp/ferry-run-${state##*/.ferry-}/kubelet.yaml" > "$share/kubelet.yaml"

log="$here/build/macos-node.log"
"$here/build/macvm" pod "$golden" "$here/.cache/node-0" --same-id --share "$share" -- \
    /bin/sh -c "$(cat "$here/macos-node-guest.sh")" node > "$log" 2>&1 &
vm=$!
# However this script ends, the guest is told to finish, or it sits on one of
# the Mac's two macOS guest slots for fifteen minutes.
trap 'touch "$share/done"' EXIT
until grep -q '^STARTED' "$log"; do
    kill -0 $vm 2>/dev/null || { cat "$log"; exit 1; }; sleep 0.5
done
started=$(date +%s)
# What follows only reports; a query that fails is part of the report.
set +e
trap - ERR

ready=
for _ in $(seq 180); do
    if [ "$(k get node "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ]; then
        ready=1; break
    fi
    sleep 1
done
{
    if [ -n "$ready" ]; then echo "=== $name Ready $(( $(date +%s) - started )) s after the kubelet started"
    else echo "=== $name not Ready after 180 s"; fi
    k get nodes -o wide -L ferry.dev/mode 2>&1 | sed 's/^/    /'
    echo "--- what the node reports"
    k get node "$name" -o jsonpath='    os/arch: {.status.nodeInfo.operatingSystem}/{.status.nodeInfo.architecture}  osImage: {.status.nodeInfo.osImage}  kernel: {.status.nodeInfo.kernelVersion}
    runtime: {.status.nodeInfo.containerRuntimeVersion}  handlers: {.status.runtimeHandlers[*].name}
    capacity: {.status.capacity}
    taints: {.spec.taints}
' 2>&1
    k get csr 2>&1 | grep -i "$name\|bootstrap" | tail -3 | sed 's/^/    /'

    if [ -n "$ready" ] && [ -n "${WORKLOAD:-}" ]; then
        . "$WORKLOAD"
    elif [ -n "$ready" ]; then
        echo "--- a ferry-macos-shared pod"
        k apply -f - >/dev/null <<EOF
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata: {name: ferry-macos-shared, labels: {experiment: "39"}}
handler: ${HANDLER:-ferry-darwin}
scheduling:
  nodeSelector: {ferry.dev/mode: shared-macos}
  tolerations: [{key: ferry.dev/mode, operator: Equal, value: shared-macos, effect: NoSchedule}]
---
apiVersion: v1
kind: Pod
metadata: {name: hello-macos, labels: {experiment: "39"}}
spec:
  runtimeClassName: ferry-macos-shared
  restartPolicy: Never
  containers: [{name: hello, image: "${IMAGE:-example.com/hello-darwin:1}", command: ["/bin/hello"]}]
EOF
        for _ in $(seq 60); do
            phase=$(k get pod hello-macos -o jsonpath='{.status.phase}' 2>/dev/null)
            case "$phase" in Running|Succeeded|Failed) break ;; esac
            sleep 1
        done
        k get pod hello-macos -o wide 2>&1 | sed 's/^/    /'
        k get events --field-selector involvedObject.name=hello-macos -o custom-columns=REASON:.reason,MESSAGE:.message 2>&1 \
            | tail -6 | cut -c1-200 | sed 's/^/    /'
        k logs hello-macos 2>&1 | head -5 | sed 's/^/    log: /'
        k delete pod hello-macos --wait=false >/dev/null 2>&1 || true
    fi
} > "$here/build/macos-node-host.log" 2>&1

touch "$share/done"
wait $vm || true
k delete node "$name" >/dev/null 2>&1 || true
k -n kube-system delete secret "bootstrap-token-$id" >/dev/null 2>&1 || true
cat "$here/build/macos-node-host.log"
grep -v '^STARTED' "$log"
