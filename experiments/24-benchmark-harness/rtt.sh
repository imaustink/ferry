#!/usr/bin/env bash
# How long one API round trip costs from inside the node.
#
# Ferry's apiserver is a macOS process and its kubelet is inside a VM, so every
# watch delivery and status write crosses that boundary. Kind's apiserver and
# kubelet share a kernel and a loopback. docs/BENCHMARKING.md shows ferry
# winning every kubelet phase it controls while losing the total by ~0.2s, so
# the gap is outside the kubelet -- this prices the part of "outside" that the
# two architectures do not share.
#
# Timed inside the guest, start to finish, so it is a duration on one clock.
# Host/guest clock offset never enters it.
set -uo pipefail
cd "$(dirname "$0")"

N="${N:-200}"
STACK="${1:?usage: rtt.sh ferry|kind}"

case "$STACK" in
  ferry)
    kc="$(./ferry kubeconfig)"
    node=perf-0
    # The Mac's address on the machine network -- what the node's kubelet talks
    # to. 127.0.0.1:8443 is the same apiserver seen from the host side.
    url="https://192.168.202.1:8443/healthz"
    ;;
  kind)
    kc="$HOME/.kube/config-perfk"
    node="$(KUBECONFIG=$kc kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
    ip="$(KUBECONFIG=$kc kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}')"
    url="https://$ip:6443/healthz"
    ;;
  *) echo "usage: rtt.sh ferry|kind" >&2; exit 2 ;;
esac

echo "== $STACK: $N round trips to $url from inside $node"

KUBECONFIG="$kc" kubectl delete pod rttprobe --ignore-not-found >/dev/null 2>&1
cat <<YAML | KUBECONFIG="$kc" kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: rttprobe}
spec:
  hostNetwork: true
  nodeName: $node
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
  containers:
  - name: c
    image: curlimages/curl:8.11.1
    command: ["sh","-c"]
    args:
    - |
      # One curl, many URLs: the connection is established once and reused, so
      # this times the round trip rather than the TLS handshake.
      # -o pairs with each URL in order; without one per URL curl prints the
      # bodies of all but the first and they land in the timing output.
      args=""
      i=0
      while [ \$i -lt $N ]; do args="\$args -o /dev/null $url"; i=\$((i+1)); done
      curl -s -k -w '%{time_total}\n' \$args
YAML

KUBECONFIG="$kc" kubectl wait --for=condition=Ready pod/rttprobe --timeout=180s >/dev/null 2>&1
for _ in $(seq 1 120); do
  phase="$(KUBECONFIG=$kc kubectl get pod rttprobe -o jsonpath='{.status.phase}' 2>/dev/null)"
  [ "$phase" = "Succeeded" ] || [ "$phase" = "Failed" ] && break
  sleep 1
done

KUBECONFIG="$kc" kubectl logs rttprobe 2>/dev/null | python3 -c '
import sys, statistics
v = [float(x)*1000 for x in sys.stdin if x.strip()]
if not v:
    print("  no samples"); raise SystemExit(1)
# The first is the connection setup, not a round trip.
head, rest = v[0], v[1:] or v
rest.sort()
def pct(p): return rest[min(len(rest)-1, int(len(rest)*p))]
print(f"  n={len(rest)}  first(connect)={head:.1f}ms")
print(f"  median={statistics.median(rest):.2f}ms  mean={statistics.fmean(rest):.2f}ms")
print(f"  p90={pct(.90):.2f}ms  p99={pct(.99):.2f}ms  min={rest[0]:.2f}ms  max={rest[-1]:.2f}ms")
'
KUBECONFIG="$kc" kubectl delete pod rttprobe --ignore-not-found >/dev/null 2>&1
