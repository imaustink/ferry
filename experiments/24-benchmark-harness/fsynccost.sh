#!/usr/bin/env bash
# What one durable write costs inside each node.
#
# burst.py shows ferry's first pod beating kind's (720ms vs 804ms) and its last
# pod losing badly (1403ms vs 979ms) -- a spread of 683ms against 175ms over 20
# pods. That is not a constant offset; it is roughly 34ms of serialized per-pod
# work against kind's 9ms.
#
# containerd's metadata store is bbolt: one writer at a time, and a transaction
# per sandbox that commits durably before it returns. If ferry's durable write
# is slower, that lock is held longer and every queued pod waits behind it.
#
# The probe calls fsync itself from Python and reads a monotonic clock.
# BusyBox has no `date %N`, no `dd oflag=dsync`, and its `time` will not time a
# shell function, so every shell-level way of asking this returns zeros. Same
# image both stacks.
set -uo pipefail
cd "$(dirname "$0")"

STACK="${1:?usage: fsynccost.sh ferry|kind}"
case "$STACK" in
  ferry) kc="$(./ferry kubeconfig)"; node=perf-0 ;;
  kind)  kc="$HOME/.kube/config-perfk"
         node="$(KUBECONFIG=$kc kubectl get nodes -o jsonpath='{.items[0].metadata.name}')" ;;
  *) echo "usage: fsynccost.sh ferry|kind" >&2; exit 2 ;;
esac

N="${N:-300}"
echo "== $STACK: durable writes on containerd's filesystem inside $node"

KUBECONFIG="$kc" kubectl delete pod fsprobe --ignore-not-found >/dev/null 2>&1
sleep 2

cat > /tmp/fsprobe.py <<PYEOF
import os, time, statistics
d = "/host/var/lib/containerd"
if not os.path.isdir(d):
    d = "/host/var/lib"
p = os.path.join(d, ".fsprobe")
buf = b"\0" * 4096
plain, fsync = [], []
fd = os.open(p, os.O_CREAT | os.O_WRONLY, 0o600)
try:
    for _ in range(20):
        os.pwrite(fd, buf, 0); os.fsync(fd)
    for _ in range($N):
        t = time.monotonic_ns(); os.pwrite(fd, buf, 0)
        plain.append(time.monotonic_ns() - t)
    for _ in range($N):
        t = time.monotonic_ns(); os.pwrite(fd, buf, 0); os.fsync(fd)
        fsync.append(time.monotonic_ns() - t)
finally:
    os.close(fd); os.unlink(p)
print("DIR", d)
print("PLAIN", statistics.median(plain) / 1e6)
print("FSYNC", statistics.median(fsync) / 1e6)
print("P90", sorted(fsync)[int(len(fsync) * 0.9)] / 1e6)
PYEOF

KUBECONFIG="$kc" kubectl create configmap fsprobe-src --from-file=probe.py=/tmp/fsprobe.py \
  --dry-run=client -o yaml | KUBECONFIG="$kc" kubectl apply -f - >/dev/null

cat <<YAML | KUBECONFIG="$kc" kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: fsprobe}
spec:
  nodeName: $node
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
  containers:
  - name: c
    image: python:3.12-alpine
    securityContext: {privileged: true}
    command: ["python3", "/src/probe.py"]
    volumeMounts:
    - {name: h, mountPath: /host}
    - {name: src, mountPath: /src}
  volumes:
  - name: h
    hostPath: {path: /}
  - name: src
    configMap: {name: fsprobe-src}
YAML

for _ in $(seq 1 300); do
  p="$(KUBECONFIG=$kc kubectl get pod fsprobe -o jsonpath='{.status.phase}' 2>/dev/null)"
  { [ "$p" = "Succeeded" ] || [ "$p" = "Failed" ]; } && break
  sleep 1
done

KUBECONFIG="$kc" kubectl logs fsprobe 2>/dev/null > /tmp/fsprobe.out
python3 - /tmp/fsprobe.out <<'PARSE'
import sys
v, d = {}, "?"
for line in open(sys.argv[1]):
    p = line.split()
    if len(p) != 2:
        continue
    if p[0] == "DIR":
        d = p[1]; continue
    try:
        v[p[0]] = float(p[1])
    except ValueError:
        pass
if "PLAIN" not in v or "FSYNC" not in v:
    print("  could not parse:", open(sys.argv[1]).read().strip()[:160] or "(empty)")
    raise SystemExit(1)
print(f"  in {d}")
print(f"  write, no barrier : {v['PLAIN']:7.3f} ms")
print(f"  write + fsync     : {v['FSYNC']:7.3f} ms   (p90 {v.get('P90', 0):7.3f})")
print(f"  -> the barrier    : {v['FSYNC'] - v['PLAIN']:7.3f} ms")
PARSE

KUBECONFIG="$kc" kubectl delete pod fsprobe --ignore-not-found >/dev/null 2>&1
KUBECONFIG="$kc" kubectl delete configmap fsprobe-src --ignore-not-found >/dev/null 2>&1
