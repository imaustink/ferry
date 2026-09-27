#!/usr/bin/env bash
# Per-pod addresses on a macOS node: boots a pod from the golden image to act
# as the node, starts three pods in it (netpod-guest.sh), and reaches them from
# this Mac at their own addresses.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
"$here/build-netpod.sh" >/dev/null
payload=$(tar czf - -C "$here/build/netpod" . | base64)
log="$here/build/netpod.log"
: > "$log"

"$here/build/macvm" pod "$here/.cache/golden" "$here/.cache/pod-net" -- \
    /bin/sh -c "$(cat "$here/netpod-guest.sh")" netpod "$payload" > "$log" 2>&1 &
vm=$!

until grep -q '^READY' "$log"; do
    kill -0 $vm 2>/dev/null || { cat "$log"; echo "node exited before READY"; exit 1; }
    sleep 0.5
done
eval "$(grep '^READY' "$log" | sed 's/^READY //')"

get() { "$here/build/netpod/bin/podsrv" get "$@" 2>&1 | sed 's/^/    /'; }
{
    echo "=== from this Mac"
    echo "--- $a:8080 (pod-a)";                           get "$a"
    echo "--- $b:8080 (pod-b)";                           get "$b"
    echo "--- $node:8080 (the node's own address)";       get "$node"
    echo "--- $a:8081 (the rogue pod, on pod-a's address)"; get "$a" 8081
} > "$here/build/netpod-host.log"

wait $vm
cat "$log" | grep -v '^READY'
cat "$here/build/netpod-host.log"
