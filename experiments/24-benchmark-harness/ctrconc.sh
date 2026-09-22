#!/usr/bin/env bash
# Does containerd serialize container creation, with the kubelet out of it?
#
# burst.py puts ferry's marginal cost at ~35ms per concurrent pod against
# kind's 11ms, and the control plane, fsync and CNI are all ruled out. That
# leaves the kubelet and containerd. This asks containerd directly, through
# ctr, with no kubelet involved:
#
#   serial   N creates one after another   -> what one create costs
#   parallel N creates all at once         -> what concurrency actually buys
#
# If parallel total is close to serial total, creation is serialized and the
# lock is inside containerd. If parallel finishes in about the time of one
# create, containerd is fine and the serialization is the kubelet's.
set -uo pipefail
cd "$(dirname "$0")"
export KUBECONFIG="$(./ferry kubeconfig)"
N="${N:-20}"

kubectl delete pod ctrprobe --ignore-not-found >/dev/null 2>&1
sleep 2
cat <<'YAML' | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: ctrprobe}
spec:
  nodeName: perf-0
  terminationGracePeriodSeconds: 0
  hostPID: true
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
kubectl wait --for=condition=Ready pod/ctrprobe --timeout=180s >/dev/null 2>&1 || { echo "no pod"; exit 1; }

# chroot into the guest so this runs the node's own ctr and its GNU date,
# which has %N. The alpine probe's BusyBox has neither.
cat > /tmp/ctrconc-inner.sh <<INNER
#!/bin/bash
set -u
export PATH=/usr/local/bin:/usr/bin:/bin
IMG=\$(ctr -n k8s.io images ls -q | grep -m1 'alpine' || true)
[ -z "\$IMG" ] && { echo "NOIMAGE"; exit 1; }
echo "IMG \$IMG"
# Prove one create actually works before timing twenty that are silenced.
echo "PROBE-BEGIN"
ctr -n k8s.io run -d --snapshotter overlayfs "\$IMG" probe0 sleep 3600 2>&1 | head -3
ctr -n k8s.io containers ls 2>&1 | head -3
ctr -n k8s.io task kill -s SIGKILL probe0 >/dev/null 2>&1
ctr -n k8s.io containers rm probe0 >/dev/null 2>&1
echo "PROBE-END"

cleanup() { for i in \$(seq 1 $N); do
  ctr -n k8s.io task kill -s SIGKILL c\$i >/dev/null 2>&1
  ctr -n k8s.io containers rm c\$i >/dev/null 2>&1
done; }
cleanup

ms() { echo \$(( \$(date +%s%N) / 1000000 )); }

# serial
t0=\$(ms)
for i in \$(seq 1 $N); do
  ctr -n k8s.io run -d --snapshotter overlayfs "\$IMG" c\$i sleep 3600 >/dev/null 2>&1
done
t1=\$(ms)
echo "SERIAL \$(( t1 - t0 ))"
cleanup

# parallel
t0=\$(ms)
for i in \$(seq 1 $N); do
  ctr -n k8s.io run -d --snapshotter overlayfs "\$IMG" c\$i sleep 3600 >/dev/null 2>&1 &
done
wait
t1=\$(ms)
echo "PARALLEL \$(( t1 - t0 ))"
cleanup
INNER

kubectl cp /tmp/ctrconc-inner.sh ctrprobe:/host/tmp/ctrconc-inner.sh >/dev/null 2>&1
kubectl exec ctrprobe -- chroot /host /bin/bash /tmp/ctrconc-inner.sh 2>&1 > /tmp/ctrconc.out
sed 's/^/  /' /tmp/ctrconc.out

python3 - /tmp/ctrconc.out "$N" <<'PARSE'
import sys
v = {}
for line in open(sys.argv[1]):
    p = line.split()
    if len(p) == 2 and p[1].isdigit():
        v[p[0]] = int(p[1])
n = int(sys.argv[2])
if "SERIAL" not in v or "PARALLEL" not in v:
    raise SystemExit(0)
s, par = v["SERIAL"], v["PARALLEL"]
print(f"\n  serial  : {s:5} ms for {n}  ->  {s/n:6.1f} ms each")
print(f"  parallel: {par:5} ms for {n}  ->  {par/n:6.1f} ms each")
print(f"  speedup from concurrency: {s/par:.2f}x  (1.0 = fully serialized)")
PARSE

kubectl delete pod ctrprobe --ignore-not-found --wait=false >/dev/null 2>&1
