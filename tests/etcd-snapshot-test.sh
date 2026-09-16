#!/usr/bin/env bash
# Proves that the snapshot an upgrade takes can actually be restored.
#
# Rollback rests entirely on this. If a control plane upgrade migrates the data
# directory, flipping the binaries back is not enough -- the older etcd cannot
# read what the newer one wrote -- so the snapshot is the only way back, and a
# snapshot nobody has ever restored is a promise rather than a feature.
#
# What this checks is the mechanics: that the flags 'ferry upgrade' passes
# produce a data directory the etcd started by control-plane/up.sh will accept,
# with the data still in it. --name and --initial-cluster have to match what
# up.sh starts etcd with, and getting them wrong gives an etcd that comes up
# empty or refuses the directory outright.
#
# Skipped when the store has no etcd yet; run 'ferry build' first.
#
#   ./tests/etcd-snapshot-test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
FERRY_ROOT="$repo"
export FERRY_ROOT
# shellcheck source=../lib/versions.sh
. "$repo/lib/versions.sh"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }

version="$(ferry_active_version)"
[ -n "$version" ] || version="$(ferry_version_list | tail -1)"
dir=""
[ -n "$version" ] && dir="$(ferry_version_dir "$version")"
if [ -z "$dir" ] || [ ! -x "$dir/etcd" ]; then
  echo "no etcd in the store; run 'ferry build' first -- skipping"
  exit 0
fi

# Ports of its own. A ferry cluster may well be running on this Mac, and this
# test must not go anywhere near its etcd.
client=23879
peer=23880
work="$(mktemp -d)"
etcd_pid=""
# Never `kill "${etcd_pid:-0}"`: pid 0 is the process group, so an empty
# variable would signal this shell and everything it started rather than the
# one etcd this test owns.
cleanup() {
  [ -n "$etcd_pid" ] && kill -KILL "$etcd_pid" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

start_etcd() { # data-dir
  "$dir/etcd" --data-dir="$1" \
    --listen-client-urls="http://127.0.0.1:$client" \
    --advertise-client-urls="http://127.0.0.1:$client" \
    --listen-peer-urls="http://127.0.0.1:$peer" \
    --initial-advertise-peer-urls="http://127.0.0.1:$peer" \
    --initial-cluster="default=http://127.0.0.1:$peer" \
    >>"$work/etcd.log" 2>&1 &
  etcd_pid=$!
  # Stop tracking it as a job. Otherwise the shell announces "Terminated: 15"
  # when it reaps it, on its own schedule, in the middle of the test's output.
  disown "$etcd_pid" 2>/dev/null
  local _
  for _ in $(seq 1 40); do
    "$dir/etcdctl" --endpoints="127.0.0.1:$client" endpoint health >/dev/null 2>&1 && return 0
    kill -0 "$etcd_pid" 2>/dev/null || return 1
    sleep 0.5
  done
  return 1
}
stop_etcd() {
  [ -n "${etcd_pid:-}" ] || return 0
  kill -TERM "$etcd_pid" 2>/dev/null
  local _
  for _ in $(seq 1 20); do kill -0 "$etcd_pid" 2>/dev/null || break; sleep 0.5; done
  kill -KILL "$etcd_pid" 2>/dev/null
  etcd_pid=""
}

printf '\033[1m%s\033[0m\n' "snapshot and restore ($version, $(ferry_etcd_version "$version"))"

if start_etcd "$work/data"; then ok "etcd started"
else bad "etcd did not start"; tail -5 "$work/etcd.log"; exit 1; fi

"$dir/etcdctl" --endpoints="127.0.0.1:$client" put /ferry/before "the upgrade" >/dev/null 2>&1 \
  && ok "wrote a key" || bad "could not write a key"

if "$dir/etcdctl" --endpoints="127.0.0.1:$client" snapshot save "$work/snapshot.db" >/dev/null 2>&1
then ok "snapshot saved ($(du -h "$work/snapshot.db" | cut -f1))"
else bad "snapshot save failed"; fi

# Something written after the snapshot. It must NOT survive the restore -- that
# is the loss 'ferry upgrade rollback' warns about, and the warning is only
# honest if it is true.
"$dir/etcdctl" --endpoints="127.0.0.1:$client" put /ferry/after "written later" >/dev/null 2>&1
stop_etcd
ok "etcd stopped"

# Exactly the call ferry's etcd_restore makes.
tool="$dir/etcdutl"
[ -x "$tool" ] || tool="$dir/etcdctl"
if "$tool" snapshot restore "$work/snapshot.db" \
     --data-dir "$work/restored" --name default \
     --initial-cluster "default=http://127.0.0.1:$peer" \
     --initial-advertise-peer-urls "http://127.0.0.1:$peer" >/dev/null 2>&1
then ok "restored with $(basename "$tool")"
else bad "snapshot restore failed"; fi

if start_etcd "$work/restored"; then ok "etcd started on the restored directory"
else bad "etcd would not start on the restored directory"; tail -5 "$work/etcd.log"; fi

got="$("$dir/etcdctl" --endpoints="127.0.0.1:$client" get /ferry/before --print-value-only 2>/dev/null)"
if [ "$got" = "the upgrade" ]; then ok "the key from before the snapshot is there"
else bad "the key is gone (got '$got')"; fi

got="$("$dir/etcdctl" --endpoints="127.0.0.1:$client" get /ferry/after --print-value-only 2>/dev/null)"
if [ -z "$got" ]; then ok "the key written after it is not, as rollback warns"
else bad "a key written after the snapshot survived it (got '$got')"; fi

stop_etcd

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[1m%s\033[0m\n' "$pass passed"
else
  printf '\033[1m%s\033[0m\n' "$pass passed, $fail failed"
  exit 1
fi
