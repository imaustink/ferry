#!/usr/bin/env bash
# Does the release tarball carry everything ferry reaches for at runtime?
#
# release/build.sh copies a hand-written list of paths, and has always said
# this file checks that list against reality. It did not exist, so the list was
# only ever checked by installing a release and waiting for it to fail -- which
# is the expensive way to find out, because the failure lands on someone else's
# Mac, after a 500MB download, on a command that worked perfectly in the
# checkout it was built from.
#
# The check is the other direction from the one you would write first. Rather
# than reading build.sh's list and confirming each entry exists, it reads every
# "$here/..." in ferry and lib/, and asks of each: does the tarball have it?
# That way a path ferry *grows* is caught, which is the failure that actually
# happens -- nobody forgets to ship a file they were already shipping, they add
# a new one and package it the old way.
#
# A reference that is deliberately absent goes in the case block below. Those
# arms are the point of the test as much as the assertions are: they are the
# written record of which paths only exist in a checkout, and every one of them
# is behind an is_release guard in ferry.
#
#   ./tests/release-test.sh [path/to/ferry-vX.Y.Z-darwin-arm64.tar.gz]
#
# Skipped when there is no tarball, like the etcd suite: a release is not
# something every checkout has lying around.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }

tarball="${1:-}"
if [ -z "$tarball" ]; then
  # Newest, so a checkout that has built several releases tests the one it just
  # made rather than whichever sorts first.
  tarball="$(find "$repo/dist" -maxdepth 1 -name 'ferry-*-darwin-arm64.tar.gz' -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null | head -1)"
fi
if [ -z "$tarball" ] || [ ! -f "$tarball" ]; then
  echo "no release tarball in dist/; run './release/build.sh' first -- skipping"
  exit 0
fi

printf '\033[1m%s\033[0m\n' "$(basename "$tarball")"

# Every path inside, with the ferry-vX.Y.Z/ prefix and any trailing slash gone.
contents="$(tar -tzf "$tarball" | sed -e 's#^[^/]*/##' -e 's#/$##' | sort -u)"
[ -n "$contents" ] || { bad "the tarball is empty or unreadable"; exit 1; }

# Is this path in the tarball, either as itself or as a directory with
# something under it?
shipped() { # path
  printf '%s\n' "$contents" | grep -qx -- "$1" && return 0
  printf '%s\n' "$contents" | grep -q "^$1/" && return 0
  return 1
}

printf '\033[1m%s\033[0m\n' "what an installed ferry needs at all"
for required in ferry VERSION lib/versions.sh lib/ports.sh bin/kubelet \
                bin/ferry-cri bin/ferry-proxyd kernel/vmlinux-arm64 \
                control-plane/up.sh manifests/coredns.yaml; do
  if shipped "$required"; then ok "$required"; else bad "$required is not in the tarball"; fi
done

printf '\033[1m%s\033[0m\n' "every path ferry opens at runtime"
# The paths ferry and the libraries it sources reach for. Literal references
# only: a path built from a variable cannot be checked from here, and pretending
# otherwise would make this test lie in the reassuring direction.
# shellcheck disable=SC2016 # $here is the literal being searched for, not expanded
refs="$(grep -ohE '\$here/[A-Za-z0-9_./-]+' "$repo/ferry" "$repo"/lib/*.sh 2>/dev/null \
  | sed -e 's#^\$here/##' -e 's#/$##' | sort -u)"
[ -n "$refs" ] || bad "no \$here/ references found -- this test is reading the wrong thing"

missing=""
for ref in $refs; do
  # Path arithmetic rather than a file.
  [ "$ref" = ".." ] && continue
  [ -z "$ref" ] && continue

  case "$ref" in
    # Building is what a checkout is for, and ferry refuses these on a release
    # with a message naming the reason. Shipping them would mean shipping the
    # sources they drive.
    build-kubelet.sh|ferry-cni/build.sh|guest/build-nft.sh|kernel/build-kernel.sh) continue ;;
    experiments/*) continue ;;
    # The Go and Swift source trees, each reached as '( cd "$here/<x>" && build )'.
    # bin/<x> is the shipped half and is checked above.
    ferry-cri|ferry-gpud|ferry-karpenter|ferry-netpol|ferry-proxy|ferry-registry|ferry-storage|ferry-streamer) continue ;;
    # Written at runtime from node-image/oci, not carried. Shipping it would add
    # ~400MB of mostly-zero sparse file for something ferry makes in seconds.
    node-image/node.ext4) continue ;;
  esac

  if shipped "$ref"; then
    ok "$ref"
  else
    bad "ferry reads \$here/$ref, and the tarball does not carry it"
    missing="$missing $ref"
  fi
done

if [ -n "$missing" ]; then
  echo
  echo "      Either copy it in release/build.sh, or -- if it is only for"
  echo "      building -- add it to the case block in this file and make sure"
  echo "      ferry guards it with is_release."
fi

printf '\033[1m%s\033[0m\n' "the Kubernetes it ships"
# v0.5.0 went out at v1.34.0 with a source that defaults to v1.37.0: build.sh
# packaged the checkout's active version, which the last cluster started there
# had switched to v1.34. A release at anything but its own default has to have
# been asked for with --kubernetes-version, and then this is the reminder.
prefix="$(tar -tzf "$tarball" | head -1 | cut -d/ -f1)"
shipped_k8s="$(tar -xOzf "$tarball" "$prefix/VERSION" 2>/dev/null | sed -n 's/^kubernetes=//p')"
default_k8s="$(tar -xOzf "$tarball" "$prefix/lib/versions.sh" 2>/dev/null \
  | sed -n 's/^FERRY_DEFAULT_K8S_VERSION="\(.*\)"/\1/p')"
if [ -n "$shipped_k8s" ] && [ "$shipped_k8s" = "$default_k8s" ]; then
  ok "kubernetes $shipped_k8s, the default its source is written for"
else
  bad "ships kubernetes ${shipped_k8s:-?}, but its source defaults to ${default_k8s:-?}"
fi

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[1m%d passed\033[0m\n' "$pass"
else
  printf '\033[1m%d passed, %d failed\033[0m\n' "$pass" "$fail"
  exit 1
fi
