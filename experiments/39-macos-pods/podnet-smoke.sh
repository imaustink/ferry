#!/usr/bin/env bash
# The bind rewrite on the host, no root: a wildcard bind lands on FERRY_POD_IP.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
n="$here/build/netpod"
DYLD_INSERT_LIBRARIES="$n/lib/podnet.dylib" FERRY_POD_IP=127.0.0.1 "$n/bin/podsrv" serve smoke &
pid=$!
sleep 0.5
"$n/bin/podsrv" get 127.0.0.1
kill $pid
