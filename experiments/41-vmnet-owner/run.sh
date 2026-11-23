#!/usr/bin/env bash
# The trials behind FINDINGS.md. Each uses its own subnet, because a refused ask
# renews a reservation (experiment 22) and would spoil a later trial's answer.
set -uo pipefail
cd "$(dirname "$0")"
dir="$(mktemp -d)"; trap 'pkill -f "owner owner 192.168.8" 2>/dev/null; rm -rf "$dir"' EXIT
gw() { echo "192.168.$1.1"; }

owner_up() { # n
  ./owner owner "$(gw "$1")" "$dir/$1" >"$dir/$1.log" 2>&1 & echo $! >"$dir/$1.pid"
  for _ in $(seq 50); do [ -s "$dir/$1" ] && return 0; sleep 0.1; done
  echo "owner $1 did not come up: $(cat "$dir/$1.log")"; exit 1
}
join_up() { # n -> pid on stdout
  ./owner join "$dir/$1" >"$dir/$1.join.log" 2>&1 & local p=$!
  for _ in $(seq 50); do grep -q holding "$dir/$1.join.log" 2>/dev/null && break; sleep 0.1; done
  echo "    $(tr '\n' ' ' <"$dir/$1.join.log")" >&2
  echo "$p"
}

echo "T1  owner releases cleanly, then the subnet is asked for"
owner_up 81; kill -TERM "$(cat "$dir/81.pid")"; sleep 0.2
./owner create "$(gw 81)"

echo "T2  owner dies uncleanly (kill -9) with no interfaces on the network; asked for"
owner_up 82; kill -9 "$(cat "$dir/82.pid")"; sleep 0.2
./owner create "$(gw 82)"

echo "T3  a client dies uncleanly while the owner holds; another client joins after it"
owner_up 83; p="$(join_up 83)"; kill -9 "$p"; sleep 0.2
p="$(join_up 83)"; kill -9 "$p"; kill -TERM "$(cat "$dir/83.pid")"

echo "T4  a client dies uncleanly, then the owner releases cleanly; the subnet is asked for"
owner_up 84; p="$(join_up 84)"; kill -9 "$p"; sleep 0.2
kill -TERM "$(cat "$dir/84.pid")"; sleep 0.2
./owner create "$(gw 84)"

echo "T5  the subnet is asked for while the owner holds it"
owner_up 85; ./owner create "$(gw 85)"; kill -TERM "$(cat "$dir/85.pid")"
