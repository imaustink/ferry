#!/usr/bin/env bash
# The shim's ClusterIP rewrite on this Mac, no root: a table naming a made-up
# ClusterIP, a podsrv behind it on loopback, and a podsrv connecting to the
# ClusterIP through the shim.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
n="$here/build/netpod"
"$here/build-netpod.sh" >/dev/null
table="$here/build/ferry-services"
printf 'tcp 10.96.0.99:80 127.0.0.1:8080\n' > "$table"
DYLD_INSERT_LIBRARIES="$n/lib/podnet.dylib" FERRY_POD_IP=127.0.0.1 "$n/bin/podsrv" serve backend &
pid=$!
sleep 0.5
echo "--- through the shim, to 10.96.0.99:80"
DYLD_INSERT_LIBRARIES="$n/lib/podnet.dylib" FERRY_SERVICES="$table" "$n/bin/podsrv" get 10.96.0.99 80
kill $pid
