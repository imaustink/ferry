#!/usr/bin/env bash
# What node_credential costs 'ferry node add': signing a new certificate, and
# the check on every later start. Against a throwaway CA.
set -u
repo="$(cd "$(dirname "$0")/../.." && pwd)"
FERRY_HOME="$(mktemp -d)"; trap 'rm -rf "$FERRY_HOME"' EXIT
mkdir -p "$FERRY_HOME/pki"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$FERRY_HOME/pki/ca.key" \
  -out "$FERRY_HOME/pki/ca.crt" -days 1 -subj /CN=ca 2>/dev/null
printf 'users:\n- user:\n    client-certificate: x\n    client-key: y\n' > "$FERRY_HOME/kubelet.conf"
bad() { echo "$1" >&2; }
eval "$(sed -n '/^node_credential()/,/^}/p' "$repo/ferry")"
now() { python3 -c 'import time; print(time.time())'; }
for kind in sign check; do
  total=0
  for i in 1 2 3 4 5; do
    [ "$kind" = sign ] && rm -f "$FERRY_HOME/pki/nodes/n$i".*
    t0=$(now); node_credential "n$i" >/dev/null; t1=$(now)
    total=$(echo "$total + ($t1 - $t0) * 1000" | bc)
  done
  printf '  %-6s mean of 5: %.0f ms\n' "$kind" "$(echo "$total / 5" | bc -l)"
done
