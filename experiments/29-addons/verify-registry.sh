#!/bin/bash
k="${K:-kubectl}"   # KUBECONFIG set to the cluster under test
crane="${CRANE:-crane}"
for i in $(seq 1 30); do curl -fs -o /dev/null http://localhost:5001/v2/ && break; sleep 1; done
echo "catalog after the registry pod was replaced: $($crane catalog localhost:5001 | tr '\n' ' ')"
# A fresh image, pushed and pulled for the first time, timed end to end.
start=$(date +%s)
$crane copy --platform linux/arm64 alpine:3.20 localhost:5001/e29/alpine:3.20 2>/dev/null
$k run pull-fresh --restart=Never --image=localhost:5001/e29/alpine:3.20 -- cat /etc/alpine-release >/dev/null
$k wait --for=jsonpath='{.status.phase}'=Succeeded pod/pull-fresh --timeout=120s >/dev/null
echo "push + pull + run localhost:5001/e29/alpine:3.20: $(( $(date +%s) - start ))s, printed $($k logs pull-fresh)"
$k delete pod pull-fresh >/dev/null
