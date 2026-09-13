#!/usr/bin/env bash
# Can a pod inside one Mac's vmnet network be reached from another Mac?
#
# This is the cheap question underneath multi-machine clusters. If a host route
# is enough, ferry's cross-machine pod network is the ordinary Kubernetes model --
# each node owns a CIDR, each host routes its peers -- and nothing has to be
# built. If it is not enough, ferry owns the datapath or tunnels, both of which
# are much larger.
#
#   on the Mac running ferry:   ./two-mac-route-test.sh target
#   on the other Mac:           ./two-mac-route-test.sh probe <macA-lan-ip> <pod-cidr> <pod-ip>
set -uo pipefail

case "${1:-}" in
target)
  export KUBECONFIG="${KUBECONFIG:-$HOME/.ferry/admin.conf}"
  kubectl delete pod routetarget --force --grace-period=0 >/dev/null 2>&1
  kubectl run routetarget --image=busybox --restart=Never \
    --command -- sh -c "echo reached-a-pod-on-the-other-mac > /tmp/index.html; httpd -f -p 8080 -h /tmp" >/dev/null
  kubectl wait --for=condition=Ready pod/routetarget --timeout=300s >/dev/null 2>&1 || {
    echo "the target pod did not start"; exit 1; }
  ip="$(kubectl get pod routetarget -o jsonpath='{.status.podIP}')"
  cidr="$(echo "$ip" | cut -d. -f1-3).0/24"
  lan="$(ipconfig getifaddr en0 || ipconfig getifaddr en7)"
  echo "forwarding : $(sysctl -n net.inet.ip.forwarding)  (1 is required)"
  echo "reachable here: $(curl -s -m5 "http://$ip:8080" || echo FAILED)"
  echo
  echo "Now run this on the other Mac:"
  echo "  ./two-mac-route-test.sh probe $lan $cidr $ip"
  ;;

probe)
  lan="${2:?macA lan ip}"; cidr="${3:?pod cidr}"; ip="${4:?pod ip}"
  echo "before the route: $(curl -s -m4 "http://$ip:8080" || echo 'no answer (expected)')"
  echo
  echo "adding a route for $cidr via $lan (needs sudo once)"
  sudo route -n delete -net "$cidr" >/dev/null 2>&1
  sudo route -n add -net "$cidr" "$lan" || { echo "could not add the route"; exit 1; }
  echo
  echo "ping    : $(ping -c2 -t3 "$ip" >/dev/null 2>&1 && echo reachable || echo 'no reply')"
  echo "http    : $(curl -s -m6 "http://$ip:8080" || echo 'no answer')"
  echo "path    :"; traceroute -n -w1 -m4 "$ip" 2>&1 | head -5
  echo
  echo "to undo: sudo route -n delete -net $cidr"
  ;;
*)
  echo "usage: $0 target"
  echo "       $0 probe <macA-lan-ip> <pod-cidr> <pod-ip>"; exit 2 ;;
esac
