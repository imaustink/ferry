#!/usr/bin/env bash
# Deletes CoreDNS n times (force, or graceful) and reports where it came back.
K=kubectl   # with KUBECONFIG pointing at the cluster
mode="${1:-force}" n="${2:-3}"
for i in $(seq 1 "$n"); do
  start=$(python3 -c 'import time; print(time.time())')
  if [ "$mode" = force ]; then
    $K -n kube-system delete pod -l k8s-app=kube-dns --force --grace-period=0 >/dev/null 2>&1
  else
    $K -n kube-system delete pod -l k8s-app=kube-dns --wait=false >/dev/null 2>&1
  fi
  for _ in $(seq 1 120); do
    line="$($K -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}|{.status.podIP}|{.spec.nodeName}|{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | grep -v '^[0-9]' | grep 'true$' | head -1)"
    [ -n "$line" ] && break
    sleep 1
  done
  end=$(python3 -c 'import time; print(time.time())')
  printf '%s %d: %s  (%.1fs to Ready)\n' "$mode" "$i" "$line" "$(echo "$end - $start" | bc)"
  pod="$($K get pod -o name 2>/dev/null | head -1)"
done
