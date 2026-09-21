#!/usr/bin/env bash
# What the CRI sandbox path costs, serial and concurrent, with no kubelet.
#
# ctrconc.sh showed containerd creating 20 plain containers in 165ms with a 6x
# speedup from concurrency, while 20 pods take 1370ms. But `ctr run` is not the
# path the kubelet uses: a pod is RunPodSandbox (pause container + network
# namespace + CNI) and then CreateContainer/StartContainer. This exercises the
# CRI itself, through crictl, on both stacks with the same binary and the same
# request.
#
#   burst.py   ferry 35.0ms per concurrent pod, kind 11.3ms
#
# If RunPodSandbox serializes here the way pods do, the cost is in containerd's
# CRI plugin and the kubelet is innocent. If it does not, the kubelet's own
# per-pod work is what is queueing.
set -uo pipefail
cd "$(dirname "$0")"

STACK="${1:?usage: criconc.sh ferry|kind}"
N="${N:-12}"
CRICTL_SRC="${CRICTL_SRC:-$HOME/.cache/ferry-bench/crictl}"

case "$STACK" in
  ferry)
    kc="$(cd ../.. && ./ferry kubeconfig)"; node=perf-0
    # cgroupfs driver: cgroup_parent is a path.
    cgparent="/kubelet" ;;
  kind)
    kc="$HOME/.kube/config-perfk"
    node="$(KUBECONFIG=$kc kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
    # systemd driver: runc demands a slice, and rejects a path outright.
    cgparent="kubelet.slice" ;;
  *) echo "usage: criconc.sh ferry|kind" >&2; exit 2 ;;
esac
export KUBECONFIG="$kc"

kubectl delete pod criprobe --ignore-not-found >/dev/null 2>&1
sleep 2
cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: criprobe}
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
kubectl wait --for=condition=Ready pod/criprobe --timeout=180s >/dev/null 2>&1 || { echo "no probe"; exit 1; }

# kind ships crictl; ferry's node does not, so carry one in. Same version
# either way, so the client is not part of the comparison.
if ! kubectl exec criprobe -- sh -c 'test -x /host/usr/local/bin/crictl' 2>/dev/null; then
  [ -f "$CRICTL_SRC" ] || { echo "  need crictl at $CRICTL_SRC"; exit 1; }
  kubectl cp "$CRICTL_SRC" criprobe:/host/tmp/crictl >/dev/null 2>&1
  kubectl exec criprobe -- sh -c 'chmod +x /host/tmp/crictl' >/dev/null 2>&1
  CRICTL=/tmp/crictl
else
  CRICTL=/usr/local/bin/crictl
fi

cat > /tmp/criconc-inner.sh <<INNER
#!/bin/sh
set -u
C="$CRICTL --runtime-endpoint unix:///run/containerd/containerd.sock -t 60s"
mk() { cat > /tmp/sb\$1.json <<J
{"metadata":{"name":"crib\$1","uid":"crib-uid-\$1","namespace":"cribench","attempt":1},
 "log_directory":"/tmp","linux":{"cgroup_parent":"$cgparent","security_context":{"namespace_options":{"network":2}}}}
J
}
i=1; while [ \$i -le $N ]; do mk \$i; i=\$((i+1)); done

cleanup() {
  for id in \$(\$C pods -q --namespace cribench 2>/dev/null); do
    \$C rmp -f "\$id" >/dev/null 2>&1
  done
}
cleanup

ms() { echo \$(( \$(date +%s%N) / 1000000 )); }

t0=\$(ms)
i=1; while [ \$i -le $N ]; do \$C runp /tmp/sb\$i.json >/dev/null 2>&1; i=\$((i+1)); done
t1=\$(ms)
echo "SERIAL \$(( t1 - t0 ))"
cleanup

t0=\$(ms)
i=1; while [ \$i -le $N ]; do \$C runp /tmp/sb\$i.json >/dev/null 2>&1 & i=\$((i+1)); done
wait
t1=\$(ms)
echo "PARALLEL \$(( t1 - t0 ))"
n=\$(\$C pods -q --namespace cribench 2>/dev/null | wc -l)
echo "CREATED \$n"
cleanup
INNER

kubectl cp /tmp/criconc-inner.sh criprobe:/host/tmp/criconc-inner.sh >/dev/null 2>&1
kubectl exec criprobe -- chroot /host /bin/sh /tmp/criconc-inner.sh > /tmp/criconc-$STACK.out 2>&1

echo "== $STACK: RunPodSandbox x $N (network=NODE, so no CNI in the way)"
python3 - "/tmp/criconc-$STACK.out" "$N" <<'PARSE'
import sys
v = {}
for line in open(sys.argv[1], errors="replace"):
    p = line.split()
    if len(p) == 2 and p[1].lstrip("-").isdigit():
        v[p[0]] = int(p[1])
n = int(sys.argv[2])
if "SERIAL" not in v or "PARALLEL" not in v:
    print("  could not parse:", open(sys.argv[1]).read().strip()[:200] or "(empty)")
    raise SystemExit(0)
made = v.get("CREATED", -1)
if made != n:
    print(f"  WARNING: {made} of {n} sandboxes created -- timings below are partly of failures")
s, par = v["SERIAL"], v["PARALLEL"]
print(f"  serial  : {s:6} ms  ->  {s/n:7.1f} ms each")
print(f"  parallel: {par:6} ms  ->  {par/n:7.1f} ms each")
print(f"  speedup from concurrency: {s/par:.2f}x   (1.0 = fully serialized)")
PARSE

kubectl delete pod criprobe --ignore-not-found --wait=false >/dev/null 2>&1
