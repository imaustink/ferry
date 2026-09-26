#!/usr/bin/env bash
# Which addresses a Seatbelt network-bind rule can name. Per-pod addresses on a
# macOS node need a profile that lets a pod bind its own IP and nothing else.
set -uo pipefail
for host in '*' localhost 127.0.0.1 192.168.64.201; do
    profile="(version 1)(allow default)(deny network-bind)(allow network-bind (local ip \"$host:8080\"))"
    printf '%-18s ' "$host:8080"
    /usr/bin/sandbox-exec -p "$profile" /usr/bin/true 2>&1 && echo "accepted"
done
