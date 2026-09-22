#!/usr/bin/env bash
# The stall, named.
#
# reachability.sh showed the wait after Running is entirely TCP -- buildctl adds
# ~45 ms on top of a socket opening -- and that the slow runs are exactly the
# ones handed a pod address a previous pod had used. This checks the obvious
# consequence: that the Mac's ARP table still maps that address to the dead
# pod's MAC, and that traffic is being sent to a machine that no longer exists
# until the entry ages out.
#
# If that is what is happening, the entry the Mac holds and the MAC the pod
# actually has will disagree while the socket refuses to open, and agree the
# moment it does.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/lib.sh"

manifest() {
  sed 's/imagePullPolicy: .*/imagePullPolicy: IfNotPresent/' \
    "$here/manifests/${BUILDER_MANIFEST:-buildkitd-sized.yaml}"
}

arp_mac() { arp -an | awk -v ip="($1)" '$2 == ip {print $4}'; }

kc delete pod buildkitd --ignore-not-found --wait=true >/dev/null 2>&1
sleep 2
echo "  ARP table before the pod exists:"
arp -an | grep -E '10\.161\.' | sed 's/^/    /'

manifest | kc apply -f - >/dev/null 2>&1
for _ in $(seq 1 6000); do
  [ "$(kc get pod buildkitd -o jsonpath='{.status.phase}' 2>/dev/null)" = Running ] && break
  sleep 0.05
done
ip="$(kc get pod buildkitd -o jsonpath='{.status.podIP}')"

# What the Mac thinks, and what the pod actually is. The exec path goes through
# ferry-streamer rather than over the pod network, so it works even while the
# direct route does not -- which is the whole point.
held="$(arp_mac "$ip")"
real="$(kc exec buildkitd -- cat /sys/class/net/eth0/address 2>/dev/null | tr -d '\r\n')"
echo
echo "  pod            $ip"
echo "  ARP says       ${held:-<no entry>}"
echo "  pod really is  ${real:-<could not read>}"

t0=$(now_ms)
for _ in $(seq 1 6000); do
  nc -z -G 1 -w 1 "$ip" 1234 >/dev/null 2>&1 && break
  sleep 0.05
done
echo "  socket opened after $(( $(now_ms) - t0 )) ms"
echo "  ARP now says   $(arp_mac "$ip")"
