#!/usr/bin/env bash
# Regression tests for the three bugs the first real cluster upgrade found.
#
# All three lived on the far side of a running API server, so none of them were
# reachable from the other suites -- which is why running it on a cluster found
# them and 100 assertions did not. This closes that gap with a stub kubectl
# (tests/stub/kubectl) that answers from files, so the paths can be driven
# without a cluster and, crucially, the timing that caused the worst of the
# three can be reproduced on purpose rather than waited for.
#
# The bugs:
#
#   1. A node that had upgraded correctly was reported as not having, because
#      the version was read the moment the node went Ready and a node object
#      keeps the old kubelet's status until the new one posts its own.
#   2. The summary said "every node on this Mac is X" and then listed one of
#      those same nodes under "nodes on other Macs", because it filtered by
#      version rather than by which Mac runs them.
#   3. With the checkout behind the cluster, the restart guard pointed at
#      'ferry upgrade apply <older>' -- a command that correctly refuses.
#
#   ./tests/node-upgrade-test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

# Named t_* because sourcing ferry brings in its own ok/bad/warn, and those
# have to keep working -- this suite reads what they print.
t_pass=0; t_fail=0
t_ok()  { t_pass=$((t_pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
t_bad() { t_fail=$((t_fail + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
heading() { printf '\033[1m%s\033[0m\n' "$1"; }

says() { # description output needle
  case "$2" in
    *"$3"*) t_ok "$1" ;;
    *) t_bad "$1"; echo "      looked for '$3' in:"; printf '%s\n' "$2" | sed 's/^/        /' ;;
  esac
}
lacks() { # description output needle
  case "$2" in
    *"$3"*) t_bad "$1"; echo "      did not want '$3' in:"; printf '%s\n' "$2" | sed 's/^/        /' ;;
    *) t_ok "$1" ;;
  esac
}
is() { # description actual expected
  if [ "$2" = "$3" ]; then t_ok "$1"; else t_bad "$1"; echo "      got:  '$2'"; echo "      want: '$3'"; fi
}

sandbox="$(mktemp -d)"
cleanup() {
  # Only processes whose arguments name this sandbox: the stub kubelets started
  # by start_kubelet, and nothing else on the machine.
  pkill -f "$sandbox" 2>/dev/null
  rm -rf "$sandbox"
}
trap cleanup EXIT

# --- a checkout that is not this one --------------------------------------

cp "$repo/ferry" "$sandbox/ferry"
ln -s "$repo/lib" "$sandbox/lib"
mkdir -p "$sandbox/bin" "$sandbox/home" "$sandbox/stub" "$sandbox/path" \
         "$sandbox/run"/{logs,containerlogs,pki,kubelet}

cp "$here/stub/kubectl" "$sandbox/path/kubectl"
chmod +x "$sandbox/path/kubectl"
PATH="$sandbox/path:$PATH"
export PATH FERRY_STUB="$sandbox/stub"

# A kubelet that starts and stays up, so stop_kubelet has something real to
# stop and start_kubelet has something real to start.
cat > "$sandbox/bin/kubelet" <<'KUBELET'
#!/bin/sh
exec sleep 300
KUBELET
chmod +x "$sandbox/bin/kubelet"

store_version() { # version
  mkdir -p "$sandbox/bin/versions/$1"
  local name
  for name in kubelet kube-apiserver kube-controller-manager kube-scheduler etcd; do
    printf '#!/bin/sh\necho %s\n' "$1" > "$sandbox/bin/versions/$1/$name"
    chmod +x "$sandbox/bin/versions/$1/$name"
  done
}
store_version v1.34.0
store_version v1.34.11

touch "$sandbox/home/kubelet.conf" "$sandbox/home/admin.conf"
printf 'apiVersion: v1\nkind: KubeletConfiguration\n' > "$sandbox/run/kubelet.yaml"

export FERRY_PROFILE=node-upgrade-test
export FERRY_PROFILES="$sandbox/profiles"
export FERRY_HOME="$sandbox/home"
export FERRY_RUN="$sandbox/run"
export FERRY_KUBECONFIG="$sandbox/home/admin.conf"
# Short, so a node that never reports the right version fails in a second
# rather than in two minutes.
export FERRY_NODE_READY_TIMEOUT=5
export FERRY_DRAIN_TIMEOUT=5s

# ferry's functions, without running a command. The dispatch at the bottom acts
# on whatever it is given; 'kubeconfig' only prints a path.
# shellcheck source=../ferry disable=SC1091
. "$sandbox/ferry" kubeconfig >/dev/null 2>&1

# --- fixtures -------------------------------------------------------------

# The cluster the stub will describe.
cluster() { # apiserver-version
  printf '%s' "$1" > "$sandbox/stub/apiserver"
  : > "$sandbox/stub/nodes"
  : > "$sandbox/stub/calls"
  rm -f "$sandbox/stub"/stale-* "$sandbox/stub/drain-exit"
}
node() { # name version ready
  printf '%s %s %s\n' "$1" "$2" "$3" >> "$sandbox/stub/nodes"
}
# Make a node report an old version for its next few reads, the way a real one
# does between a kubelet restart and that kubelet posting its status.
reports_stale() { # name reads old-version
  printf '%s %s\n' "$2" "$3" > "$sandbox/stub/stale-$1"
}
# A node on this Mac, with a kubelet running for it.
local_node() { # name
  printf '%s' "$1" > "$sandbox/run/node-name"
  "$sandbox/bin/kubelet" >/dev/null 2>&1 &
  local pid=$!
  # Stop tracking it as a job, or the shell announces "Terminated: 15" when the
  # upgrade stops it, in the middle of this suite's output.
  disown "$pid" 2>/dev/null
  echo "$pid" > "$sandbox/run/kubelet.pid"
}
active() { printf '%s' "$1" > "$sandbox/bin/.active-version"; }

# --- 1. the version read that came too early ------------------------------

heading "a node whose status lags the kubelet that replaced it"

cluster v1.34.11
node ferry-mac v1.34.11 True
# Three reads of the old version first: the node has upgraded, but its object
# has not caught up. This is the bug, made deterministic.
reports_stale ferry-mac 3 v1.34.0
local_node ferry-mac
active v1.34.11

out="$(cmd_upgrade_node ferry-mac 2>&1)"
says "it waits for the version to change rather than reading it straight away" \
     "$out" "node Ready, kubelet v1.34.11"
lacks "so it never reports the version that was just replaced" \
      "$out" "kubelet v1.34.0"
says "it drained first"   "$(cat "$sandbox/stub/calls")" "drain ferry-mac"
says "honouring budgets"  "$(cat "$sandbox/stub/calls")" "--ignore-daemonsets"
says "and uncordoned after" "$(cat "$sandbox/stub/calls")" "uncordon ferry-mac"

heading "a node that really does come back on the wrong version"

cluster v1.34.11
node ferry-mac v1.34.0 True
# No stale file: it reports v1.34.0 for good. The wait must give up and say so
# rather than announcing success with whatever it happened to read.
local_node ferry-mac
active v1.34.11

out="$(cmd_upgrade_node ferry-mac 2>&1)"
says "it says what the node actually reports" \
     "$out" "is Ready but reports v1.34.0, not v1.34.11"
lacks "and does not claim the node came back at the target" \
      "$out" "node Ready, kubelet v1.34.11"
says "leaving it cordoned, and saying so" "$out" "still cordoned"

heading "a node that does not come back at all"

cluster v1.34.11
# Behind the target, so the upgrade actually runs, and never Ready afterwards.
node ferry-mac v1.34.0 False
local_node ferry-mac
active v1.34.11

out="$(cmd_upgrade_node ferry-mac 2>&1)"
says "it reports the node, not the version" "$out" "did not come back Ready"
lacks "and does not blame the version for it" "$out" "is Ready but reports"

# --- 2. local nodes listed as being on another Mac ------------------------

heading "the summary after rolling every node on this Mac"

cluster v1.34.11
node ferry-mac v1.34.11 True
node other-mac v1.34.0 True
reports_stale ferry-mac 2 v1.34.0
local_node ferry-mac
active v1.34.11

out="$(cmd_upgrade_nodes 2>&1)"
says "it says this Mac is done"        "$out" "every node on this Mac is v1.34.11"
says "and names the Mac that is not"   "$out" "other-mac (v1.34.0)"
lacks "without listing a node it just upgraded as someone else's" \
      "$out" "ferry-mac (v1.34.0)"

heading "when every node in the cluster is already at the target"

cluster v1.34.11
node ferry-mac v1.34.11 True
node other-mac v1.34.11 True
local_node ferry-mac
active v1.34.11

out="$(cmd_upgrade_nodes 2>&1)"
lacks "there is nothing said about other Macs" "$out" "other Macs"

heading "a node on another Mac cannot be upgraded from this one"

cluster v1.34.11
node ferry-mac v1.34.11 True
node other-mac v1.34.0 True
local_node ferry-mac
active v1.34.11

out="$(cmd_upgrade_node other-mac 2>&1)"
says "it says so"                 "$out" "is not a node this Mac runs"
says "lists what this Mac has"    "$out" "ferry-mac"
says "and says where to run it"   "$out" "run 'ferry upgrade node other-mac' on it"
lacks "without draining anything" "$(cat "$sandbox/stub/calls")" "drain"

# --- 3. the restart guard pointing at a command that refuses --------------

heading "starting a cluster whose version the checkout has moved away from"

guard_output() { # cluster-version checkout-version [previous-version]
  printf 'kubernetes=%s\ncontrol-plane=%s\netcd=v3.6.5\n' "$1" "$1" > "$sandbox/home/version"
  if [ -n "${3:-}" ]; then
    printf 'kubernetes=%s\ncontrol-plane=%s\netcd=v3.6.5\n' "$3" "$3" > "$sandbox/home/version.previous"
  else
    rm -f "$sandbox/home/version.previous"
  fi
  active "$2"
  align_to_cluster_version 2>&1
}

out="$(guard_output v1.34.0 v1.34.11)"
says "a newer checkout is offered as an upgrade" \
     "$out" "ferry upgrade apply v1.34.11"

# The bug: this used to say "ferry upgrade apply v1.34.0", which 'apply'
# refuses, because a control plane does not go backwards in place.
out="$(guard_output v1.34.11 v1.34.0 v1.34.0)"
says "an older checkout the cluster came from is offered as a rollback" \
     "$out" "ferry upgrade rollback"
lacks "and not as an apply, which would refuse" \
      "$out" "ferry upgrade apply v1.34.0"

out="$(guard_output v1.34.11 v1.34.0)"
lacks "an older checkout it did not come from is not offered an apply either" \
      "$out" "ferry upgrade apply v1.34.0"
says "it explains why instead" "$out" "does not go backwards in place"

out="$(guard_output v1.34.11 v1.34.11)"
is "and nothing is said when the two agree" "$out" ""

heading "starting a cluster whose version is no longer built"

printf 'kubernetes=v1.33.0\ncontrol-plane=v1.33.0\netcd=v3.5.21\n' > "$sandbox/home/version"
active v1.34.11
out="$(align_to_cluster_version 2>&1)"
says "it refuses rather than starting the wrong version" \
     "$out" "this cluster last ran v1.33.0, and the binaries for it are gone"
says "and says how to get them"  "$out" "ferry build --kubernetes-version v1.33.0"

echo
if [ "$t_fail" -eq 0 ]; then
  heading "$t_pass passed"
else
  heading "$t_pass passed, $t_fail failed"
  exit 1
fi
