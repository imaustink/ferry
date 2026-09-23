#!/usr/bin/env bash
# Who the control plane's ferry-netpol peer port answers, and with what.
# usage: peer-port.sh <host:port> <ca.crt> <name>=<cert>,<key> ... [-- <foreign cert>,<key>]
# Prints, for each certificate, the pod sections and edge pods it is served;
# then what a caller with no certificate and one from another CA get.
set -u
addr="$1" ca="$2"; shift 2
ask() { # cert key path
  curl -s --max-time 5 --cacert "$ca" ${1:+--cert "$1" --key "$2"} -w '\n%{http_code}' "https://$addr$3"
}
foreign=""
for arg in "$@"; do
  [ "$arg" = "--" ] && { foreign=1; continue; }
  if [ -n "$foreign" ]; then
    cert="${arg%,*}" key="${arg#*,}"
    out="$(ask "$cert" "$key" /rules 2>&1)"; code="${out##*$'\n'}"
    echo "  another cluster's node: HTTP ${code:-none} (curl exit $(ask "$cert" "$key" /rules >/dev/null 2>&1; echo $?))"
    continue
  fi
  name="${arg%%=*}" pair="${arg#*=}"; cert="${pair%,*}" key="${pair#*,}"
  rules="$(ask "$cert" "$key" /rules)"
  edge="$(ask "$cert" "$key" /edge)"
  echo "  $name: pods $(echo "$rules" | grep '^## ' | cut -c4- | tr '\n' ' ')| edge $(echo "$edge" | head -1 | tr -d '\n' | cut -c1-120)"
done
code="$(curl -s -o /dev/null --max-time 5 --cacert "$ca" -w '%{http_code}' "https://$addr/rules")"
echo "  no certificate: HTTP $code (curl exit $(curl -s -o /dev/null --max-time 5 --cacert "$ca" "https://$addr/rules"; echo $?))"
