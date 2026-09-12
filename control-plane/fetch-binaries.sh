#!/usr/bin/env bash
# Downloads native darwin/arm64 control plane binaries.
#
# Upstream publishes no darwin build of the control plane -- only kubectl -- so
# these come from kwok-ci/k8s, which cross-builds them for exactly this reason.
# Those builds are explicitly unofficial and dev/test only. Building from
# kubernetes source with KUBE_BUILD_PLATFORMS=darwin/arm64 is the eventual fix;
# see docs/TODO. etcd, by contrast, ships darwin/arm64 officially.
set -euo pipefail

K8S_VERSION="${K8S_VERSION:-v1.34.11}"
ETCD_VERSION="${ETCD_VERSION:-v3.6.5}"
here="$(cd "$(dirname "$0")" && pwd)"
bin="$here/../bin"
mkdir -p "$bin"

k8s_tag="${K8S_VERSION}-kwok.0-darwin-arm64"
for c in kube-apiserver kube-controller-manager kube-scheduler; do
  if [ -x "$bin/$c" ]; then echo "    = $c"; continue; fi
  echo "    + $c ($K8S_VERSION)"
  curl -fsSL -o "$bin/$c" \
    "https://github.com/kwok-ci/k8s/releases/download/$k8s_tag/$c"
  chmod +x "$bin/$c"
done

if [ ! -x "$bin/etcd" ]; then
  echo "    + etcd ($ETCD_VERSION)"
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/etcd.zip" \
    "https://github.com/etcd-io/etcd/releases/download/$ETCD_VERSION/etcd-$ETCD_VERSION-darwin-arm64.zip"
  ( cd "$tmp" && unzip -q etcd.zip )
  install -m 0755 "$tmp/etcd-$ETCD_VERSION-darwin-arm64/etcd" "$bin/etcd"
  install -m 0755 "$tmp/etcd-$ETCD_VERSION-darwin-arm64/etcdctl" "$bin/etcdctl"
  rm -rf "$tmp"
else
  echo "    = etcd"
fi

echo "==> versions"
"$bin/etcd" --version | head -1
for c in kube-apiserver kube-controller-manager kube-scheduler; do
  printf '%-26s' "$c"; "$bin/$c" --version
done
