#!/usr/bin/env bash
# DNS, a ClusterIP and each other pod directly, from one pod.
# usage: from-pod.sh <pod> <service>...   with KUBECONFIG pointing at the cluster (admin)
set -u
K=kubectl
pod="$1"; shift
dns="$($K get pod -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[0].status.podIP}')"
printf '  %-30s %s\n' "nslookup kubernetes.default" \
  "$($K exec "$pod" -- nslookup kubernetes.default.svc.cluster.local 2>&1 | grep -A1 '^Name:' | tail -1)"
printf '  %-30s %s\n' "resolv.conf" "$($K exec "$pod" -- grep nameserver /etc/resolv.conf 2>&1)"
printf '  %-30s %s\n' "nslookup at CoreDNS $dns" \
  "$($K exec "$pod" -- nslookup kubernetes.default.svc.cluster.local "$dns" 2>&1 | grep -A1 '^Name:' | tail -1)"
printf '  %-30s %s\n' "ping CoreDNS pod $dns" \
  "$($K exec "$pod" -- ping -c1 -W2 "$dns" 2>&1 | grep -o '[0-9]* packets received')"
for svc in "$@"; do
  ip="$($K get pod "$svc" -o jsonpath='{.status.podIP}' 2>/dev/null)"
  cip="$($K get svc "$svc" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
  printf '  %-30s %s\n' "ClusterIP $svc ($cip)" "$($K exec "$pod" -- wget -q -T 3 -O - "http://$cip/" 2>&1 | tail -1)"
  printf '  %-30s %s\n' "pod $svc ($ip)" "$($K exec "$pod" -- wget -q -T 3 -O - "http://$ip/" 2>&1 | tail -1)"
done
