#!/usr/bin/env bash
# Which phase of a pod start stretches when twenty arrive at once.
#
# Everything measured so far has been from outside the kubelet -- the API's
# clock, containerd's log, crictl. Each of those ruled something out and none
# of them could say what the kubelet was doing between being told about a pod
# and asking the runtime for it. This asks the kubelet, which logs its own
# per-pod boundaries, and splits the burst the same way for both stacks.
#
# phases.py is the parser and has been here since the first round with nothing
# calling it: reading the log meant knowing where each stack keeps it, that
# kind's is in journalctl and ferry's is a file inside a guest, and that a
# 20-pod burst has to be running while you look. That is this script.
#
# Usage: podphases.sh ferry|kind [replicas]
#
# FERRY_KUBELET_V=4 at `ferry up` gets the finer boundaries on ferry's side;
# the four this reports are logged at v=2 by both, so the comparison holds
# either way and does not depend on having rebuilt anything.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/stacks.sh"

STACK="${1:-ferry}"
N="${2:-20}"
PROBE=phaseprobe

case "$STACK" in
  ferry|ferry2)
    kc="$(kubeconfig_of ferry2)"; ctx=""
    # The machine node -- the one mode 2 adds. Asking for it by label rather
    # than by name keeps this working on a cluster whose Machine is not called
    # worker-0, which the first version of these instruments hardcoded.
    node="$(KUBECONFIG=$kc kubectl get nodes \
      -l ferry.dev/mode=shared -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
    [ -n "$node" ] || { echo "  no ferry.dev/mode=shared node; is mode 2 on?"; exit 1; }
    sel="ferry.dev/mode=shared" ;;
  kind)
    kc="$(kubeconfig_of kind)"; ctx="$(context_of kind)"
    node="$(KUBECONFIG=$kc kubectl --context "$ctx" get nodes \
      -o jsonpath='{.items[0].metadata.name}')"
    sel="-" ;;
  *) echo "usage: podphases.sh ferry|kind [replicas]" >&2; exit 2 ;;
esac
echo "== $STACK, $N pods, node $node"

# --- reading the kubelet's log -------------------------------------------
#
# Two different places. kind runs the kubelet under systemd inside its node
# container, so journalctl has it -- bounded with --since, because an
# unbounded `journalctl -n` returns history rather than the window just
# measured, which is how an earlier run here parsed a 5.4-hour span without
# complaining. ferry's node is a VM with no journal and no exec; the kubelet
# writes a file, and a privileged pod with the guest root mounted reads it.
start_probe() {
  [ "$STACK" = kind ] && return 0
  KUBECONFIG="$kc" kubectl delete pod "$PROBE" --ignore-not-found >/dev/null 2>&1
  cat <<YAML | KUBECONFIG="$kc" kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: $PROBE}
spec:
  nodeName: $node
  terminationGracePeriodSeconds: 0
  containers:
  - name: c
    image: alpine:3.20
    command: ["sleep","3600"]
    securityContext: {privileged: true, runAsUser: 0}
    volumeMounts: [{name: h, mountPath: /host}]
  volumes:
  - name: h
    hostPath: {path: /}
YAML
  KUBECONFIG="$kc" kubectl wait --for=condition=Ready "pod/$PROBE" --timeout=180s >/dev/null 2>&1 \
    || { echo "  probe pod never became Ready"; exit 1; }
}

kubelet_log() { # since_iso
  if [ "$STACK" = kind ]; then
    docker exec "$node" journalctl -u kubelet --since "$1" --no-pager -o short-precise 2>/dev/null
  else
    KUBECONFIG="$kc" kubectl exec "$PROBE" -- sh -c 'cat /host/var/log/kubelet.log' 2>/dev/null
  fi
}

start_probe

# The probe is itself a pod on the node under test, so it is created before
# the burst and left alone during it: starting it in the middle would put its
# own sandbox in the measurement.
since="$(date -u -v-1M '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u '+%Y-%m-%d %H:%M:%S')"

echo "== burst"
python3 "$BENCH_HOME/burst.py" "$kc" "$sel" "$N" 1

# Read once and reused: on ferry this is an exec into a guest, and the log is
# megabytes at --v=4.
log="$(mktemp -t podphases)"
kubelet_log "$since" > "$log"
echo
echo "  kubelet log: $(wc -l < "$log" | tr -d ' ') lines"

# burst.py names each round b<uuid>; the probe and kube-system are excluded by
# matching only that shape, so a slow coredns cannot be read as a slow burst.
echo
echo "== the four coarse phases, which both kubelets log at v=2"
python3 "$BENCH_HOME/phases.py" 'burst/b[0-9a-f]{8}-' < "$log"

echo
echo "== inside syncPod, which needs --v=4"
python3 "$BENCH_HOME/syncphases.py" 'burst/b[0-9a-f]{8}-' < "$log"
rm -f "$log"

if [ "$STACK" != kind ]; then
  KUBECONFIG="$kc" kubectl delete pod "$PROBE" --ignore-not-found >/dev/null 2>&1 &
fi
