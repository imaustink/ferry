#!/usr/bin/env bash
# Does a joined Mac keep enforcing when the control plane's ferry-netpol goes?
# usage: upstream-down.sh <control-plane FERRY_RUN> <hostport>
# with KUBECONFIG pointing at the cluster, and e34web (on the joined node) and
# e34cli (on the first) running -- policy.sh with KEEP=1 leaves them.
#
# Applies a deny-all, stops the control plane's ferry-netpol, *deletes* the
# policy while it is down, and checks the joined pod is still closed 40s
# later: the last rules received stay in force, even stale ones. Then starts
# ferry-netpol again with the arguments it had, and times until the pod and
# the edge open. The edge is told apart by curl's exit: 7 is refused by
# policy, 28 is a timeout, which is not policy.
set -u
run="$1" hp="$2"
ip="$(kubectl get pod e34web -o jsonpath='{.status.podIP}')"
pod() { kubectl exec e34cli -- wget -q -T 2 -O - "http://$ip/" >/dev/null 2>&1 && echo open || echo closed; }
edge() { curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$hp/"; case $? in 0) echo open;; 7|52|56) echo refused;; *) echo "timeout($?)";; esac; }
now() { python3 -c 'import time; print("%.2f" % time.time())'; }

kubectl apply -f - >/dev/null <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: e35-deny}
spec: {podSelector: {}, policyTypes: [Ingress]}
YAML
sleep 2
echo "  deny-all, upstream up:         pod $(pod), edge $(edge)"
pid="$(cat "$run/ferry-netpol.pid")"
args="$(ps -o command= -p "$pid")"
kill "$pid"
kubectl delete networkpolicy e35-deny >/dev/null
sleep 40
echo "  policy deleted, upstream down 40s: pod $(pod), edge $(edge)"
start="$(now)"
$args >>"$run/logs/ferry-netpol.log" 2>&1 &
echo $! > "$run/ferry-netpol.pid"
until [ "$(edge)" = open ]; do sleep 0.1; done
t_edge="$(now)"
until [ "$(pod)" = open ]; do sleep 0.1; done
t_pod="$(now)"
python3 -c "print('  upstream back: edge open after %.2fs, pod after %.2fs' % ($t_edge - $start, $t_pod - $start))"
