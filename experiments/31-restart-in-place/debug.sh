#!/usr/bin/env bash
# `kubectl debug -i` into crash2: an ephemeral container joins the running
# pod, and the client attaches to its stdin.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
kubectl apply -f "$here/crash.yaml" >/dev/null
kubectl wait --for=condition=Ready pod/crash2 --timeout=60s >/dev/null
printf 'echo hello-from-debug; hostname; exit\n' |
  timeout 40 kubectl debug -i crash2 --image=busybox:1.36 -c "dbg$RANDOM" -- sh 2>&1 | tail -4
kubectl exec crash2 -c steady -- ps -o pid,etime,args | head -2
