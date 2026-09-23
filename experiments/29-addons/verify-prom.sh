#!/bin/bash
k="${K:-kubectl}"   # KUBECONFIG set to the cluster under test
$k -n monitoring port-forward svc/prometheus 29090:9090 >/dev/null 2>&1 &
pf=$!
trap 'kill $pf' EXIT
for i in $(seq 1 30); do curl -s -o /dev/null http://localhost:29090/-/ready && break; sleep 0.5; done
echo "targets:"
curl -s http://localhost:29090/api/v1/targets | jq -r '.data.activeTargets[] | "  \(.labels.job) \(.scrapeUrl) \(.health) \(.lastError)"'
q() { curl -s --data-urlencode "query=$1" http://localhost:29090/api/v1/query | jq -r --arg q "$1" '"  \($q) = \(.data.result | length) series, e.g. \(.data.result[0].value[1] // "none")"'; }
q 'kube_pod_status_phase{phase="Running"} == 1'
q 'kube_deployment_status_replicas_available'
q 'apiserver_request_total'
q 'kubelet_running_pods'
q 'container_memory_working_set_bytes'
q 'container_cpu_usage_seconds_total'
