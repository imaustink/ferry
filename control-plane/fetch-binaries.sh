#!/usr/bin/env bash
# Downloads native darwin/arm64 control plane binaries into the version store.
#
# Upstream publishes no darwin build of the control plane -- only kubectl -- so
# these come from kwok-ci/k8s, which cross-builds them for exactly this reason.
# Those builds are explicitly unofficial and dev/test only. Building from
# kubernetes source with KUBE_BUILD_PLATFORMS=darwin/arm64 is the eventual fix;
# see docs/TODO. etcd, by contrast, ships darwin/arm64 officially.
#
# What this used to do was skip the download whenever bin/kube-apiserver
# existed, at a default version nothing passed in. That made the control plane
# unmovable: it was fetched once, at whatever version was the default that day,
# and no later request for a different one could dislodge it. The cache is now
# keyed by version, which is what makes an upgrade possible at all.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
FERRY_ROOT="$(cd "$here/.." && pwd)"
export FERRY_ROOT
# shellcheck source=../lib/versions.sh
. "$FERRY_ROOT/lib/versions.sh"

K8S_VERSION="${K8S_VERSION:-$FERRY_DEFAULT_K8S_VERSION}"
ferry_version_valid "$K8S_VERSION" \
  || { echo "K8S_VERSION=$K8S_VERSION is not a version like v1.34.0" >&2; exit 1; }

# The version the cluster is called, which is the kubelet's, and the two
# versions that answer to it.
CONTROL_PLANE_VERSION="$(ferry_control_plane_version "$K8S_VERSION")"
ETCD_VERSION="$(ferry_etcd_version "$K8S_VERSION")"
dir="$(ferry_version_dir "$K8S_VERSION")"
mkdir -p "$dir"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

k8s_tag="${CONTROL_PLANE_VERSION}-kwok.0-darwin-arm64"
for c in kube-apiserver kube-controller-manager kube-scheduler; do
  if [ -x "$dir/$c" ]; then echo "    = $c"; continue; fi
  echo "    + $c ($CONTROL_PLANE_VERSION)"
  if ! curl -fsSL -o "$tmp/$c" \
      "https://github.com/kwok-ci/k8s/releases/download/$k8s_tag/$c"; then
    echo >&2
    echo "could not download $c for $CONTROL_PLANE_VERSION." >&2
    echo >&2
    echo "kwok-ci/k8s does not build every patch release, and ferry pins one" >&2
    echo "per minor in lib/versions.sh. If $CONTROL_PLANE_VERSION is not one it" >&2
    echo "published, name a release that exists:" >&2
    echo >&2
    echo "    K8S_CONTROL_PLANE_VERSION=vX.Y.Z ferry build --kubernetes-version $K8S_VERSION" >&2
    echo >&2
    echo "Releases: https://github.com/kwok-ci/k8s/releases" >&2
    exit 1
  fi
  ferry_install_binary "$K8S_VERSION" "$c" "$tmp/$c"
done

# etcdutl is separate from etcdctl and matters here: etcd 3.6 removed `etcdctl
# snapshot restore`, and restoring a snapshot is the only way back from a
# control plane upgrade that migrated the data directory. Fetching it at the
# same time means rollback does not depend on the machine having it already.
if [ ! -x "$dir/etcd" ] || [ ! -x "$dir/etcdctl" ] || [ ! -x "$dir/etcdutl" ]; then
  echo "    + etcd ($ETCD_VERSION)"
  curl -fsSL -o "$tmp/etcd.zip" \
    "https://github.com/etcd-io/etcd/releases/download/$ETCD_VERSION/etcd-$ETCD_VERSION-darwin-arm64.zip"
  ( cd "$tmp" && unzip -q etcd.zip )
  unpacked="$tmp/etcd-$ETCD_VERSION-darwin-arm64"
  for c in etcd etcdctl etcdutl; do
    # etcdutl arrived in 3.5; a 3.4 archive would not carry it, and a missing
    # one is not fatal -- etcdctl still restores snapshots at that version.
    [ -f "$unpacked/$c" ] || continue
    ferry_install_binary "$K8S_VERSION" "$c" "$unpacked/$c"
  done
else
  echo "    = etcd"
fi

ferry_write_manifest "$K8S_VERSION" "$CONTROL_PLANE_VERSION" "$ETCD_VERSION"

echo "==> versions"
"$dir/etcd" --version | head -1
for c in kube-apiserver kube-controller-manager kube-scheduler; do
  printf '%-26s' "$c"; "$dir/$c" --version
done
