#!/usr/bin/env bash
# Tests for the upgrade commands themselves: dispatch, argument handling, and
# every refusal that happens before anything is touched.
#
# Run against a throwaway checkout with a store full of stub binaries and no
# cluster, so nothing here can reach a real one. What that covers is the paths
# an upgrade takes when it decides not to proceed -- which is most of them, and
# the ones where being wrong is expensive. What it cannot cover is the part that
# needs a Mac with a cluster on it; docs/UPGRADES.md lists that separately.
#
#   ./tests/upgrade-cli-test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }

# A checkout that is not this one, so a test cannot write into the real bin/.
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
cp "$repo/ferry" "$sandbox/ferry"
ln -s "$repo/lib" "$sandbox/lib"
mkdir -p "$sandbox/bin" "$sandbox/home" "$sandbox/run/logs"

# No inherited kubeconfig: a test must never find a cluster to talk to.
ferry() {
  KUBECONFIG="" \
  FERRY_PROFILE=upgrade-cli-test \
  FERRY_PROFILES="$sandbox/profiles" \
  FERRY_HOME="$sandbox/home" \
  FERRY_RUN="$sandbox/run" \
    bash "$sandbox/ferry" "$@" 2>&1
}

says() { # description output needle
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1"; echo "      looked for '$3' in:"; echo "$2" | sed 's/^/        /' ;; esac
}
exits() { # description expected-code command...
  local description="$1" want="$2"; shift 2
  "$@" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$want" ]; then ok "$description"
  else bad "$description"; echo "      exited $got, wanted $want"; fi
}

store() { # version
  local dir="$sandbox/bin/versions/$1"
  mkdir -p "$dir"
  local name
  for name in kubelet ferry-proxyd kube-apiserver kube-controller-manager kube-scheduler etcd etcdctl etcdutl; do
    printf '#!/bin/sh\necho %s %s\n' "$name" "$1" > "$dir/$name"
    chmod +x "$dir/$name"
  done
}
activate() { # version
  local name
  for name in kubelet ferry-proxyd kube-apiserver kube-controller-manager kube-scheduler etcd etcdctl etcdutl; do
    rm -f "$sandbox/bin/$name"
    ln -s "versions/$1/$name" "$sandbox/bin/$name"
  done
  echo "$1" > "$sandbox/bin/.active-version"
}
cluster_at() { # version previous
  printf 'kubernetes=%s\ncontrol-plane=%s\netcd=v3.6.5\n' "$1" "$1" > "$sandbox/home/version"
  [ -n "${2:-}" ] \
    && printf 'kubernetes=%s\ncontrol-plane=%s\netcd=v3.6.5\n' "$2" "$2" > "$sandbox/home/version.previous"
}

printf '\033[1m%s\033[0m\n' "dispatch"
says "help lists the upgrade commands" "$(ferry)" "ferry upgrade apply"
says "help mentions rollback"          "$(ferry)" "ferry upgrade rollback"
says "help mentions down --purge"      "$(ferry)" "--purge"
says "an unknown subcommand says what there is" \
     "$(ferry upgrade nonsense)" "usage: ferry upgrade"
exits "and exits 2" 2 ferry upgrade nonsense
exits "down rejects an unknown flag" 2 ferry down --nonsense

printf '\033[1m%s\033[0m\n' "status on an empty checkout"
says "it says nothing is built"  "$(ferry upgrade status)" "nothing; run 'ferry build'"
says "and has no cluster version" "$(ferry upgrade status)" "cluster       -"

printf '\033[1m%s\033[0m\n' "status with a store and a cluster"
store v1.34.0
store v1.35.0
activate v1.35.0
cluster_at v1.35.0 v1.34.0
out="$(ferry upgrade status)"
says "it reports the cluster's version"   "$out" "cluster       v1.35.0"
says "and what the checkout is built at"  "$out" "this checkout v1.35.0"
says "and where rollback would go"        "$out" "rollback to   v1.34.0"
says "and lists both versions"            "$out" "v1.34.0"
says "marking the one bin/ points at"     "$out" "v1.35.0  <- bin/ points here"

printf '\033[1m%s\033[0m\n' "refusals that cost nothing to find"
cluster_at v1.34.0
activate v1.34.0
says "a downgrade is refused"       "$(ferry upgrade apply v1.33.0)" "does not support downgrading"
says "and points at rollback"       "$(ferry upgrade apply v1.33.0)" "ferry upgrade rollback"
exits "exiting non-zero"          1 ferry upgrade apply v1.33.0
says "skipping a minor is refused"  "$(ferry upgrade apply v1.36.0)" "skips 1 minor"
says "a version that is not one is refused" \
     "$(ferry upgrade apply v1.36)" "is not a version like"
says "upgrading to what is already running is a no-op" \
     "$(ferry upgrade plan v1.34.0)" "already at v1.34.0"
exits "and is not reported as a failure" 0 ferry upgrade plan v1.34.0
exits "apply says the same, and succeeds"  0 ferry upgrade apply v1.34.0
says "plan needs a version"          "$(ferry upgrade plan)" "usage: ferry upgrade plan"
exits "and exits 2"                2 ferry upgrade plan
says "apply needs a version"         "$(ferry upgrade apply)" "usage: ferry upgrade apply"
# A flag is not a version. Seeding the version from $1 before parsing made
# 'apply --yes' try to upgrade to "--yes", which would have got as far as
# building it.
says "apply --yes with no version does not take the flag for one" \
     "$(ferry upgrade apply --yes)" "usage: ferry upgrade apply"
says "node --force with no name does not take the flag for one" \
     "$(ferry upgrade node --force)" "usage: ferry upgrade node"

printf '\033[1m%s\033[0m\n' "nothing to roll back to"
rm -f "$sandbox/home/version.previous"
says "rollback says so plainly" "$(ferry upgrade rollback)" "nothing to roll back to"
exits "and exits non-zero"    1 ferry upgrade rollback
cluster_at v1.35.0 v1.34.0
rm -rf "$sandbox/bin/versions/v1.34.0"
says "rollback to a version no longer in the store explains itself" \
     "$(ferry upgrade rollback)" "no longer has v1.34.0"
says "and says how to get it back" \
     "$(ferry upgrade rollback)" "ferry build --kubernetes-version v1.34.0"

printf '\033[1m%s\033[0m\n' "a node upgrade with no credentials"
out="$(ferry upgrade node somenode)"
says "it says there is no kubeconfig"  "$out" "no kubeconfig on this Mac"
says "and names the way to give it one" "$out" "FERRY_KUBECONFIG="
exits "exiting non-zero" 1 ferry upgrade node somenode
says "node needs a name" "$(ferry upgrade node)" "usage: ferry upgrade node"

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[1m%s\033[0m\n' "$pass passed"
else
  printf '\033[1m%s\033[0m\n' "$pass passed, $fail failed"
  exit 1
fi
