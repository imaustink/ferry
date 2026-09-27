#!/bin/sh
# Runs inside a macOS guest, as root: three pods on one node, each with its own
# address, uid and root, all running a workload that binds the wildcard.
#
#   pod-a  uid 601  binds 0.0.0.0:8080
#   pod-b  uid 602  binds [::]:8080
#   rogue  uid 603  explicitly binds pod-a's address, port 8081
#
# $1 is build/netpod as a base64 tarball. Prints READY with the addresses, then
# holds the pods up for the host to reach them.
set -u
N=/private/var/ferry/netpod
P=/private/var/ferry/pods
rm -rf "$N" "$P"; mkdir -p "$N" "$P"
echo "$1" | base64 -d | tar xzf - -C "$N"

node=$(ipconfig getifaddr en0); pre=${node%.*}
A=$pre.231; B=$pre.232; C=$pre.233
# An alias on en0 answers ARP, so the Mac reaches the pod. The node itself
# would route to it out of en0 and lose it -- the network does not hairpin --
# so each address also gets a host route through loopback, the one the node's
# primary address has by default.
for ip in $A $B $C; do
    ifconfig en0 alias "$ip" 255.255.255.255
    route -q -n add -host "$ip" -interface lo0
done
echo "--- node $node, pod addresses $A $B $C as aliases on en0"

mkpod() {
    mkdir -p "$P/$1/bin" "$P/$1/lib" "$P/$1/tmp"
    cp "$N/bin/podsrv" "$P/$1/bin/"; cp "$N/lib/podnet.dylib" "$P/$1/lib/"
    chown -R "$2" "$P/$1"
}
mkpod a 601; mkpod b 602; mkpod c 603

# pf: an address answers only to its own pod's sockets, in and out.
cat > /tmp/pods.pf <<EOF
pass all
block return in  quick proto { tcp udp } to $A user != 601
block return in  quick proto { tcp udp } to $B user != 602
block return in  quick proto { tcp udp } to $C user != 603
block return out quick proto { tcp udp } from $A user != 601
block return out quick proto { tcp udp } from $B user != 602
block return out quick proto { tcp udp } from $C user != 603
EOF
pfctl -q -E -f /tmp/pods.pf 2>&1 | grep -v "ALTQ\|No ALTQ" ; echo "--- pf loaded: $(pfctl -s rules 2>/dev/null | grep -c user) user rules"

# Logs go through a pipe: the profile lets a pod write only inside its root,
# which may include a log file the runtime opened for it.
"$N/podexec" 601 "$A" "$P/a" "$P/a/bin/podsrv" serve  pod-a 2>&1 | cat > /tmp/a.log &
"$N/podexec" 602 "$B" "$P/b" "$P/b/bin/podsrv" serve6 pod-b 2>&1 | cat > /tmp/b.log &
"$N/podexec" 603 "$C" "$P/c" "$P/c/bin/podsrv" rogue  "$A" 8081 2>&1 | cat > /tmp/c.log &
t0=$(date +%s)
until grep -q bound /tmp/a.log 2>/dev/null && grep -q bound /tmp/b.log 2>/dev/null || [ $(( $(date +%s) - t0 )) -gt 30 ]; do sleep 0.2; done
echo "--- pods reported their binds after $(( $(date +%s) - t0 )) s"
pa=$(pgrep -u 601 podsrv); pb=$(pgrep -u 602 podsrv); pc=$(pgrep -u 603 podsrv)
echo "--- how the node routes to pod-b's address"
route -n get "$B" | grep -E 'interface|flags' | sed 's/^/    /'
echo "--- a plain listener on the node's own address, reached from the node"
nc -l "$node" 9999 < /dev/null > /dev/null & nl=$!
sleep 0.3; nc -z -G 2 "$node" 9999 2>&1 | sed 's/^/    /'; kill $nl 2>/dev/null
echo "--- nc (no shim, not sandboxed) to pod-b, from the node"
nc -z -G 2 "$B" 8080 2>&1 | sed 's/^/    /'
echo "--- what each pod bound"
cat /tmp/a.log /tmp/b.log /tmp/c.log | sed 's/^/    /'
echo "--- sockets listening on 8080/8081, as the node sees them"
netstat -an -p tcp | grep LISTEN | grep -E '\.808[01] ' | sed 's/^/    /'
echo "--- pod-a calls pod-b (whose address does pod-b see?)"
"$N/podexec" 601 "$A" "$P/a" "$P/a/bin/podsrv" get "$B" | sed 's/^/    /'
echo "--- the same call with pf off"
pfctl -q -d 2>/dev/null
"$N/podexec" 601 "$A" "$P/a" "$P/a/bin/podsrv" get "$B" | sed 's/^/    /'
echo "--- the rogue, with pf off, from inside the node"
"$N/bin/podsrv" get "$A" 8081 | sed 's/^/    /'
pfctl -q -e 2>/dev/null
echo "--- pod-a signals pod-b's process"
"$N/podexec" 601 "$A" "$P/a" "$P/a/bin/podsrv" kill "$pb" | sed 's/^/    /'
echo "--- pod-a reads pod-b's root"
"$N/podexec" 601 "$A" "$P/a" /bin/ls "$P/b" 2>&1 | sed 's/^/    /'

echo "READY node=$node a=$A b=$B c=$C"
sleep 25

kill $pa $pb $pc 2>/dev/null
pfctl -q -d 2>/dev/null
for ip in $A $B $C; do route -q -n delete -host "$ip"; ifconfig en0 -alias "$ip"; done
echo "--- cleaned up"
