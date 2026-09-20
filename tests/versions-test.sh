#!/usr/bin/env bash
# Tests for the version store and the skew rules.
#
# Everything an upgrade decides before it touches anything -- which version
# follows which, what the control plane and etcd for it are, where the binaries
# go and which one bin/ points at -- is arithmetic and file layout, and can be
# tested on any machine in under a second. What cannot be tested here is the
# half that needs a Mac with a cluster on it: the drain, the restart, the
# snapshot. Those are listed in docs/UPGRADES.md as what to run by hand.
#
#   ./tests/versions-test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }

is() { # description actual expected
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; echo "      got:  '$2'"; echo "      want: '$3'"; fi
}
contains() { # description haystack needle
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1"; echo "      '$2' does not contain '$3'" ;; esac
}
empty() { # description actual
  if [ -z "$2" ]; then ok "$1"; else bad "$1"; echo "      expected nothing, got '$2'"; fi
}
succeeds() { # description command...
  local description="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$description"; else bad "$description"; fi
}
refuses() { # description command...
  local description="$1"; shift
  if "$@" >/dev/null 2>&1; then bad "$description"; else ok "$description"; fi
}

# A throwaway checkout root, so nothing here can touch a real bin/.
FERRY_ROOT="$(mktemp -d)"
FERRY_HOME="$(mktemp -d)"
export FERRY_ROOT FERRY_HOME
trap 'rm -rf "$FERRY_ROOT" "$FERRY_HOME"' EXIT

# shellcheck source=../lib/versions.sh
. "$repo/lib/versions.sh"

printf '\033[1m%s\033[0m\n' "version arithmetic"
succeeds "v1.34.0 is a version"          ferry_version_valid v1.34.0
succeeds "v1.9.11 is a version"          ferry_version_valid v1.9.11
refuses  "v1.34 is not"                  ferry_version_valid v1.34
refuses  "v1.34.x is not"                ferry_version_valid v1.34.x
refuses  "1.34.0 without the v is not"   ferry_version_valid 1.34.0
refuses  "the empty string is not"       ferry_version_valid ""
refuses  "v1.34.0-rc1 is not"            ferry_version_valid v1.34.0-rc1
is "major of v1.34.0"  "$(ferry_version_major v1.34.0)" "1"
is "minor of v1.34.0"  "$(ferry_version_minor v1.34.0)" "34"
is "patch of v1.34.11" "$(ferry_version_patch v1.34.11)" "11"
is "v1.34.11 is v1.34" "$(ferry_version_mm v1.34.11)" "v1.34"

printf '\033[1m%s\033[0m\n' "what a version is paired with"
is "v1.34.0 runs the v1.34.11 control plane" \
   "$(ferry_control_plane_version v1.34.0)" "v1.34.11"
is "so does v1.34.11" "$(ferry_control_plane_version v1.34.11)" "v1.34.11"
is "v1.35.0 runs the v1.35.8 control plane" \
   "$(ferry_control_plane_version v1.35.0)" "v1.35.8"
is "v1.36.0 runs the v1.36.4 control plane" \
   "$(ferry_control_plane_version v1.36.0)" "v1.36.4"
is "an unpinned minor asks for itself" \
   "$(ferry_control_plane_version v1.99.3)" "v1.99.3"
is "the pin can be overridden" \
   "$(K8S_CONTROL_PLANE_VERSION=v1.34.9 ferry_control_plane_version v1.34.0)" "v1.34.9"
is "v1.34 pairs with etcd 3.6" "$(ferry_etcd_version v1.34.0)" "v3.6.5"
is "v1.33 pairs with etcd 3.5" "$(ferry_etcd_version v1.33.4)" "v3.5.21"
is "etcd can be overridden" \
   "$(ETCD_VERSION=v3.5.9 ferry_etcd_version v1.34.0)" "v3.5.9"

printf '\033[1m%s\033[0m\n' "every pinned minor is reachable"
# The two halves of supporting a minor have to agree, and nothing else notices
# when they stop. A pin with no patches/kubelet-vX.Y/ is a minor whose kubelet
# cannot be built; a gap in the ladder is a minor that ferry_skew_reason will
# refuse to step over, which strands every cluster below the gap on the far side
# of it. v1.36 shipped with both faults: pinned, but with no v1.35 in between.
pinned_minors="$(
  awk '/^ferry_control_plane_version\(\)/,/^}/' "$repo/lib/versions.sh" \
    | sed -n 's/^ *\(v1\.[0-9]*\)) *echo.*/\1/p'
)"
if [ -n "$pinned_minors" ]; then ok "the pins can be read out of lib/versions.sh"
else bad "no pinned minors found -- this test is reading the wrong thing"; fi
for mm in $pinned_minors; do
  if [ -d "$repo/patches/kubelet-$mm" ]; then
    ok "$mm has a kubelet overlay"
  else
    bad "$mm is pinned but patches/kubelet-$mm/ does not exist"
  fi
done
previous=""
# shellcheck disable=SC2013 # each line is a bare vX.Y, so splitting on it is fine
for mm in $(sort -t. -k2 -n <<<"$pinned_minors"); do
  if [ -n "$previous" ]; then
    step="$(( $(ferry_version_minor "$mm") - $(ferry_version_minor "$previous") ))"
    if [ "$step" = 1 ]; then
      ok "$previous steps straight to $mm"
    else
      bad "$previous to $mm skips $(( step - 1 )) minor(s), which ferry_skew_reason refuses"
    fi
  fi
  previous="$mm"
done

printf '\033[1m%s\033[0m\n' "control plane skew"
empty "a patch bump is allowed"       "$(ferry_skew_reason v1.34.0 v1.34.11)"
empty "one minor forward is allowed"  "$(ferry_skew_reason v1.33.4 v1.34.0)"
contains "two minors is refused" "$(ferry_skew_reason v1.32.0 v1.34.0)" "skips 1 minor"
contains "three minors says how many" "$(ferry_skew_reason v1.31.0 v1.34.0)" "skips 2 minor"
contains "going back a minor is refused" \
   "$(ferry_skew_reason v1.34.0 v1.33.0)" "does not support downgrading"
contains "going back points at rollback" \
   "$(ferry_skew_reason v1.34.0 v1.33.0)" "ferry upgrade rollback"
contains "a patch downgrade is still a downgrade" \
   "$(ferry_skew_reason v1.34.11 v1.34.0)" "downgrading"
contains "a major bump is refused" "$(ferry_skew_reason v1.34.0 v2.0.0)" "major version"

printf '\033[1m%s\033[0m\n' "kubelet skew"
empty "a kubelet matching the API server is fine" \
   "$(ferry_kubelet_skew_reason v1.34.0 v1.34.11)"
empty "three minors behind is fine" \
   "$(ferry_kubelet_skew_reason v1.31.0 v1.34.0)"
contains "four minors behind is not" \
   "$(ferry_kubelet_skew_reason v1.30.0 v1.34.0)" "more than three minor versions behind"
contains "a kubelet ahead of the API server is refused" \
   "$(ferry_kubelet_skew_reason v1.35.0 v1.34.0)" "is newer than the API server"
contains "and says to do the control plane first" \
   "$(ferry_kubelet_skew_reason v1.35.0 v1.34.0)" "Upgrade the control plane first"

printf '\033[1m%s\033[0m\n' "the store"
stub() { # path
  mkdir -p "$(dirname "$1")"
  printf '#!/bin/sh\necho %s\n' "$(basename "$1")" > "$1"
  chmod +x "$1"
}
staging="$(mktemp -d)"
for name in kubelet ferry-proxyd kube-apiserver kube-controller-manager kube-scheduler etcd etcdctl etcdutl; do
  stub "$staging/$name"
  ferry_install_binary v1.34.0 "$name" "$staging/$name"
done
succeeds "v1.34.0 is complete"      ferry_version_complete v1.34.0
refuses  "v1.35.0 is not there"     ferry_version_complete v1.35.0
succeeds "it activates"             ferry_activate_version v1.34.0
is "bin/ points at it"              "$(ferry_active_version)" "v1.34.0"
is "the link is relative"           "$(readlink "$FERRY_ROOT/bin/kubelet")" "versions/v1.34.0/kubelet"
succeeds "and the link runs"        "$FERRY_ROOT/bin/kubelet"

# The point of the store: installing another version leaves the first one
# intact and does not write over anything bin/ currently points at.
for name in kubelet kube-apiserver kube-controller-manager kube-scheduler etcd; do
  ferry_install_binary v1.35.0 "$name" "$staging/$name"
done
is "the old version is still linked" "$(ferry_active_version)" "v1.34.0"
is "installing did not move bin/"    "$(readlink "$FERRY_ROOT/bin/kubelet")" "versions/v1.34.0/kubelet"
ferry_activate_version v1.35.0
is "and flipping is a symlink away"  "$(readlink "$FERRY_ROOT/bin/kubelet")" "versions/v1.35.0/kubelet"
ferry_activate_version v1.34.0
is "flipping back works too"         "$(ferry_active_version)" "v1.34.0"
# v1.35.0 was installed without ferry-proxyd. Activating it has to take the
# stale v1.34.0 link away, or bin/ serves two versions at once.
ferry_activate_version v1.35.0
refuses "activating drops a link the new version does not have" \
        test -e "$FERRY_ROOT/bin/ferry-proxyd"
ferry_activate_version v1.34.0
succeeds "and brings it back when it does" \
        test -x "$FERRY_ROOT/bin/ferry-proxyd"
is "both versions are listed, oldest first" \
   "$(ferry_version_list | tr '\n' ' ')" "v1.34.0 v1.35.0 "

ferry_write_manifest v1.34.0 v1.34.11 v3.6.5
is "the manifest records the control plane" \
   "$(ferry_manifest_field v1.34.0 control-plane)" "v1.34.11"
is "and etcd" "$(ferry_manifest_field v1.34.0 etcd)" "v3.6.5"
refuses "an absent field is an error" ferry_manifest_field v1.34.0 nonsense

printf '\033[1m%s\033[0m\n' "a cluster's own version"
refuses "an unstarted cluster has none" ferry_cluster_field kubernetes
ferry_write_cluster_version v1.34.0 v1.34.11 v3.6.5
is "it records what started"   "$(ferry_cluster_field kubernetes)" "v1.34.0"
refuses "with nothing to roll back to yet" ferry_previous_field kubernetes
ferry_write_cluster_version v1.35.0 v1.35.0 v3.6.5
is "an upgrade moves it"       "$(ferry_cluster_field kubernetes)" "v1.35.0"
is "and remembers the last one" "$(ferry_previous_field kubernetes)" "v1.34.0"
ferry_write_cluster_version v1.35.0 v1.35.0 v3.6.5
is "restarting the same version does not lose the rollback target" \
   "$(ferry_previous_field kubernetes)" "v1.34.0"

printf '\033[1m%s\033[0m\n' "adopting a checkout from before the store"
legacy_root="$(mktemp -d)"
mkdir -p "$legacy_root/bin"
for name in kubelet kube-apiserver kube-controller-manager kube-scheduler etcd etcdctl; do
  stub "$legacy_root/bin/$name"
done
echo "v1.34.0" > "$legacy_root/bin/.kubelet-version"
# An inode that a running process would be holding. mv keeps it; cp would not.
before="$(stat -f %i "$legacy_root/bin/kubelet" 2>/dev/null || stat -c %i "$legacy_root/bin/kubelet")"
( FERRY_ROOT="$legacy_root" ferry_adopt_legacy_binaries ) 2>/dev/null
after="$(stat -f %i "$legacy_root/bin/versions/v1.34.0/kubelet" 2>/dev/null \
         || stat -c %i "$legacy_root/bin/versions/v1.34.0/kubelet")"
is "the old binaries became a version" \
   "$(FERRY_ROOT="$legacy_root" ferry_active_version)" "v1.34.0"
is "bin/kubelet became a link" \
   "$(readlink "$legacy_root/bin/kubelet")" "versions/v1.34.0/kubelet"
is "and kept its inode, so a running kubelet stays runnable" "$before" "$after"
refuses "the old version file is gone" test -f "$legacy_root/bin/.kubelet-version"
# Running it again must not undo any of that.
( FERRY_ROOT="$legacy_root" ferry_adopt_legacy_binaries ) 2>/dev/null
is "adopting twice is a no-op" \
   "$(readlink "$legacy_root/bin/kubelet")" "versions/v1.34.0/kubelet"
rm -rf "$legacy_root" "$staging"

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[1m%s\033[0m\n' "$pass passed"
else
  printf '\033[1m%s\033[0m\n' "$pass passed, $fail failed"
  exit 1
fi
