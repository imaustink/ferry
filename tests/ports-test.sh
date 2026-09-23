#!/usr/bin/env bash
# Tests for the port map.
#
# Every port ferry binds is a base plus PROFILE_INDEX * 1000, and added nodes
# take a block out of what is left. Whether any two of those land on the same
# number is arithmetic, which means it can be settled here rather than by a
# kubelet failing to bind in a way that reads as the cluster being slow.
#
# It is settled here because it was wrong for a long time in a way nobody
# could see: node 7's kubelet asked for kube-controller-manager's port on a
# default profile, and the streamer port had no profile shift at all, so two
# checkouts' first added node fought over one port.
#
#   ./tests/ports-test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
is() { # description actual expected
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; echo "      got:  '$2'"; echo "      want: '$3'"; fi
}

# shellcheck source=../lib/ports.sh
. "$repo/lib/ports.sh"

printf '\033[1m%s\033[0m\n' "a node's block"
is "node 1 on the default profile" "$(ferry_node_ports 0 1)"    "10701 10702 10703"
is "node 2 follows it"             "$(ferry_node_ports 0 2)"    "10704 10705 10706"
is "the last node fits"            "$(ferry_node_ports 0 "$FERRY_MAX_NODES")" "10995 10996 10997"
is "a profile shifts the block"    "$(ferry_node_ports 1000 1)" "11701 11702 11703"

# The last node has to stay inside its own profile's thousand, or it is the
# next profile's problem -- which is exactly how the old healthz port escaped.
last_stream="$(ferry_node_ports 0 "$FERRY_MAX_NODES" | awk '{print $3}')"
if [ "$last_stream" -lt 11000 ]; then
  ok "node $FERRY_MAX_NODES stays inside the profile's thousand"
else
  bad "node $FERRY_MAX_NODES reaches $last_stream, which is the next profile's"
fi

# One more node would not, which is what makes the cap the arithmetic rather
# than a number somebody liked.
over="$(ferry_node_ports 0 $(( FERRY_MAX_NODES + 1 )) | awk '{print $3}')"
if [ "$over" -ge 11000 ]; then
  ok "node $(( FERRY_MAX_NODES + 1 )) would not, so the cap is not arbitrary"
else
  bad "node $(( FERRY_MAX_NODES + 1 )) still fits at $over; the cap is too low"
fi

printf '\033[1m%s\033[0m\n' "the list of what ferry binds"

# Every port 'ferry up' binds, as a base before the profile shift.
#
# Written out rather than derived, because the derivation below is a grep and a
# grep is not a definition. What keeps it honest is that the grep has to agree
# with it: this list is the test's own statement of what ferry does, and the
# check that follows is what makes a wrong statement fail here rather than in
# whichever process loses the race a year from now.
# 8081 is karpenter's health probe. Karpenter defaults it to 8081 unshifted,
# which is how a second ferry on one Mac used to panic on startup and fall
# back to hand-declared machines; shifting it put it in this list's scope.
# 5050 is ferry-registry, only with FERRY_MACHINE_REGISTRY=1. Not 5000, which
# macOS's AirPlay receiver holds.
FERRY_UP_PORTS="6443 2379 2380 8081 10257 10259 10248 10250 10350 8472 8700 5050"

# Anything ferry adds PORT_SHIFT to is a port it binds once per profile, which
# is exactly what belongs in the list. The node block is not here and should
# not be: it comes from ferry_node_ports, which this file already calls.
# Plain sort, not sort -n: comm compares lexicographically, and feeding it a
# numerically sorted list makes it report differences that are not there.
bound="$(grep -oE '[0-9]+ \+ PORT_SHIFT' "$repo/ferry" | awk '{print $1}' | sort -u)"
declared="$(echo "$FERRY_UP_PORTS" | tr ' ' '\n' | sort -u)"

missing="$(comm -23 <(echo "$bound") <(echo "$declared"))"
if [ -z "$missing" ]; then
  ok "every profile-shifted port in ferry is one this test knows about"
else
  bad "ferry binds these with PORT_SHIFT and the list below does not have them:"
  for port in $missing; do
    echo "      $port: $(grep -n "$port + PORT_SHIFT" "$repo/ferry" | head -1 | cut -d: -f1 | sed 's/^/ferry:/')"
  done
fi

# The other direction is a weaker claim -- a port in the list that ferry no
# longer binds only makes the collision check stricter than it needs to be --
# but it is still the list going stale, so it is still worth saying.
stale="$(comm -13 <(echo "$bound") <(echo "$declared"))"
if [ -z "$stale" ]; then
  ok "and nothing in the list has stopped being a port ferry binds"
else
  bad "the list still has $(echo "$stale" | tr '\n' ' ')which ferry no longer binds"
fi

printf '\033[1m%s\033[0m\n' "nothing collides"

# Every port ferry binds, for every profile it will hand out and every node a
# profile will take, in one list. A duplicate is two processes asking the same
# kernel for the same port, and the loser is whichever started second.
claims="$(
  for p in $(seq 0 50); do
    shift_p=$(( p * 1000 ))
    # What 'ferry up' binds.
    for base in $FERRY_UP_PORTS; do
      echo "$(( base + shift_p )) profile-$p/ferry-up"
    done
    for i in $(seq 1 "$FERRY_MAX_NODES"); do
      # The pod switch: one port a node, from the relay base.
      echo "$(( 8472 + shift_p + i )) profile-$p/node-$i/switch"
      for port in $(ferry_node_ports "$shift_p" "$i"); do
        echo "$port profile-$p/node-$i"
      done
    done
  done
)"

total="$(echo "$claims" | wc -l | tr -d ' ')"
dupes="$(echo "$claims" | awk '{print $1}' | sort -n | uniq -d)"
if [ -z "$dupes" ]; then
  ok "$total ports across 51 profiles and $FERRY_MAX_NODES nodes each, no two the same"
else
  bad "these ports are claimed twice:"
  for port in $dupes; do
    echo "      $port: $(echo "$claims" | awk -v p="$port" '$1 == p {printf "%s ", $2}')"
  done
fi

# The two that actually bit, named so a future rearrangement has to keep
# clearing them rather than rediscovering them.
kubelet_1="$(ferry_node_ports 0 7 | awk '{print $1}')"
if [ "$kubelet_1" != 10257 ]; then
  ok "node 7's kubelet is not kube-controller-manager's 10257"
else
  bad "node 7's kubelet is back on kube-controller-manager's port"
fi
# Field by field, not block against block: the bug was one of the three
# missing the shift while the other two carried it, so comparing the blocks
# whole would have passed.
for field in 1:kubelet 2:healthz 3:streamer; do
  n="${field%%:*}"; what="${field##*:}"
  mine="$(ferry_node_ports 0 1 | awk -v n="$n" '{print $n}')"
  theirs="$(ferry_node_ports 1000 1 | awk -v n="$n" '{print $n}')"
  if [ "$mine" != "$theirs" ]; then
    ok "two profiles' node 1 do not share a $what port"
  else
    bad "two profiles' node 1 both bind $what on $mine; the shift is missing again"
  fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
