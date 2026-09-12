#!/usr/bin/env bash
# Builds a darwin/arm64 kubelet from upstream Kubernetes with the ferry patch
# overlay applied. Patches are kept as whole files under patches/kubelet/
# mirroring the upstream tree, plus build-tag edits below -- diffs against a
# tree this large rot too fast to be worth maintaining.
set -euo pipefail

K8S_VERSION="${K8S_VERSION:-v1.34.0}"
here="$(cd "$(dirname "$0")" && pwd)"
src="${K8S_SRC:-${TMPDIR:-/tmp}/ferry-kubernetes-$K8S_VERSION}"
out="$here/bin/kubelet"

if [ ! -d "$src" ]; then
  echo "==> cloning kubernetes $K8S_VERSION"
  git clone --depth 1 --branch "$K8S_VERSION" --single-branch \
    https://github.com/kubernetes/kubernetes.git "$src"
else
  echo "==> reusing source at $src"
  git -C "$src" checkout -- . 2>/dev/null || true
fi

echo "==> applying overlay"
(cd "$here/patches/kubelet" && find . -name '*.go' -print0) \
  | while IFS= read -r -d '' f; do
      install -m 0644 "$here/patches/kubelet/$f" "$src/$f"
      echo "    + ${f#./}"
    done

# Narrow the not-linux-not-windows fallbacks so the darwin files win. Each
# build tag is widened by hand because the upstream files carry both the new
# //go:build form and the legacy // +build comment.
echo "==> retagging superseded fallbacks"
for f in pkg/kubelet/cadvisor/cadvisor_unsupported.go \
         pkg/volume/util/hostutil/hostutil_unsupported.go \
         pkg/kubelet/cm/container_manager_unsupported.go \
         staging/src/k8s.io/mount-utils/mount_unsupported.go \
         pkg/kubelet/config/file_unsupported.go; do
  if [ -f "$src/$f" ]; then
    sed -i '' \
      -e 's|^//go:build !linux && !windows$|//go:build !linux \&\& !windows \&\& !darwin|' \
      -e 's|^// +build !linux,!windows$|// +build !linux,!windows,!darwin|' \
      "$src/$f"
    echo "    ~ $f"
  fi
done

# Static pod file watching is gated to linux purely by build tag; the code
# underneath is fsnotify, which supports darwin via kqueue and uses no
# Linux-specific API. Widen the tag rather than fork the file.
echo "==> widening portable fallbacks"
for f in pkg/kubelet/config/file_linux.go; do
  if [ -f "$src/$f" ]; then
    sed -i '' \
      -e 's|^//go:build linux$|//go:build linux \|\| darwin|' \
      -e 's|^// +build linux$|// +build linux darwin|' \
      "$src/$f"
    echo "    ~ $f"
  fi
done

# Upstream stamps the version through its own build machinery, which we are
# bypassing. Without this the kubelet reports v0.0.0-master and the node shows a
# meaningless version, which also muddies any version-skew reasoning against the
# control plane.
ldflags="$(
  for pkg in k8s.io/client-go/pkg/version k8s.io/component-base/version; do
    echo -n " -X $pkg.gitVersion=$K8S_VERSION"
    echo -n " -X $pkg.gitMajor=$(echo "$K8S_VERSION" | cut -d. -f1 | tr -d v)"
    echo -n " -X $pkg.gitMinor=$(echo "$K8S_VERSION" | cut -d. -f2)"
    echo -n " -X $pkg.gitTreeState=clean"
    echo -n " -X $pkg.buildDate=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  done
)"

echo "==> building darwin/arm64 kubelet ($K8S_VERSION)"
cd "$src"
GOFLAGS=-mod=vendor GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 \
  go build -ldflags "$ldflags" -o "$out" ./cmd/kubelet

echo "==> $out"
ls -lh "$out"
