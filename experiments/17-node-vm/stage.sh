#!/usr/bin/env bash
# Everything a Linux node needs, downloaded once on the host.
#
# The guest gets these through a shared directory rather than fetching them
# itself: the versions stay fixed, the measured path has no network in it, and a
# node that boots twenty times does not download twenty times.
#
# The kubelet's version is not a free choice -- it has to match the control
# plane it joins, which ferry builds at v1.34.x.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
STAGE="${STAGE:-$here/stage}"
mkdir -p "$STAGE"

KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.34.11}"
CONTAINERD_VERSION="${CONTAINERD_VERSION:-2.3.5}"
RUNC_VERSION="${RUNC_VERSION:-1.5.1}"
# Not a free choice either. The configuration the node image ships with
# (../18-node-image/files/containerd-config.toml) is `version = 3` and
# configures io.containerd.cri.v1.images, both of which are containerd 2.x
# only; 1.x refuses the file outright, never opens its socket, and leaves the
# node waiting a minute and then coming up with no kubelet.
case "$CONTAINERD_VERSION" in
  2.*) ;;
  *) echo "CONTAINERD_VERSION=$CONTAINERD_VERSION: the node's containerd configuration needs 2.x" >&2
     exit 1 ;;
esac
CNI_VERSION="${CNI_VERSION:-1.9.1}"

get() { # url dest
  [ -f "$2" ] && return 0
  echo "==> $(basename "$2")"
  curl -sSL -o "$2" "$1"
}

get "https://dl.k8s.io/release/$KUBERNETES_VERSION/bin/linux/arm64/kubelet" "$STAGE/kubelet"
chmod +x "$STAGE/kubelet"

# The version is recorded next to the tarball because its name does not survive
# the copy into the node image build, which checks it before baking the 2.x-only
# configuration in. get() keeps whatever is already staged, so a tarball staged
# at another version is dropped here rather than kept under a name that now
# claims to be this one.
[ "$(cat "$STAGE/containerd.version" 2>/dev/null)" = "$CONTAINERD_VERSION" ] \
  || rm -f "$STAGE/containerd.tar.gz"
get "https://github.com/containerd/containerd/releases/download/v$CONTAINERD_VERSION/containerd-$CONTAINERD_VERSION-linux-arm64.tar.gz" \
  "$STAGE/containerd.tar.gz"
printf '%s\n' "$CONTAINERD_VERSION" > "$STAGE/containerd.version"

get "https://github.com/opencontainers/runc/releases/download/v$RUNC_VERSION/runc.arm64" "$STAGE/runc"
chmod +x "$STAGE/runc"

# The kubelet reports the node NotReady until the runtime says its network is
# ready, and containerd says that only once a CNI configuration and its plugins
# are present. A node with no pod network is not a node.
get "https://github.com/containernetworking/plugins/releases/download/v$CNI_VERSION/cni-plugins-linux-arm64-v$CNI_VERSION.tgz" \
  "$STAGE/cni-plugins.tgz"

if [ ! -f "$STAGE/ca-certificates.crt" ]; then
  echo "==> CA bundle"
  cp /etc/ssl/cert.pem "$STAGE/ca-certificates.crt"
fi

ls -lh "$STAGE"
echo "==> staged in $STAGE"
