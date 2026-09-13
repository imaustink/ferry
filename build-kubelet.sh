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
         pkg/kubelet/config/file_unsupported.go \
         pkg/kubelet/kuberuntime/kuberuntime_container_unsupported.go \
         pkg/kubelet/kuberuntime/kuberuntime_sandbox_unsupported.go \
         pkg/volume/util/subpath/subpath_unsupported.go; do
  if [ -f "$src/$f" ]; then
    sed -i '' \
      -e 's|^//go:build !linux && !windows$|//go:build !linux \&\& !windows \&\& !darwin|' \
      -e 's|^// +build !linux,!windows$|// +build !linux,!windows,!darwin|' \
      "$src/$f"
    echo "    ~ $f"
  fi
done

# kube-proxy's nftables proxier is gated to linux by build tag, but what ferry
# wants from it is the rule *generation*, which is portable: it talks to a
# knftables.Interface, and knftables ships a Fake that records a transaction and
# can Dump() it. So the tag is widened and ferry_backend_darwin.go supplies the
# fake in place of the kernel. Only proxier.go moves -- the conntrack package
# stays linux-only, with ferry_conntrack_darwin.go standing in for it, because
# macOS genuinely has no connection table.
#
# Without this ferry-proxyd cannot be built at all, and Services do not route.
echo "==> widening kube-proxy's nftables proxier to darwin"
proxier="$src/pkg/proxy/nftables/proxier.go"
if [ -f "$proxier" ]; then
  sed -i '' \
    -e 's|^//go:build linux$|//go:build linux \|\| darwin|' \
    -e 's|^// +build linux$|// +build linux darwin|' \
    "$proxier"
  # The one seam. Upstream reaches straight for the host's nft; ferry needs that
  # choice to depend on the platform, so it goes through a build-tagged helper
  # that returns the real kernel on Linux and knftables' recording Fake on
  # darwin. Everything else in proxier.go is untouched.
  sed -i '' \
    -e 's|nft, err := getNFTablesInterface(ipFamily)|nft, err := ferryNFTablesInterface(ipFamily)|' \
    "$proxier"
  echo "    ~ pkg/proxy/nftables/proxier.go"
  grep -q 'ferryNFTablesInterface(ipFamily)' "$proxier" \
    || { echo "    !! the nftables seam did not apply; ferry-proxyd will not work" >&2; exit 1; }
fi

# Tell the cluster that this node runs Linux containers.
#
# The kubelet labels its node with its own GOOS, which here is darwin -- and
# nothing schedules onto a darwin node. Practically every manifest in the
# ecosystem carries nodeSelector kubernetes.io/os: linux, including
# metrics-server, ingress-nginx and most Helm charts, so a truthful label makes
# ferry unable to run the software people actually want to run.
#
# The label describes where containers run, and containers here run on Linux --
# each in its own virtual machine with a Linux kernel. `kubectl get nodes -o wide`
# still reports macOS as the OS image, which is where the Mac is honestly
# visible. This makes the label say the useful thing rather than the literal one.
echo "==> labelling the node as running linux containers"
node_status="$src/pkg/kubelet/kubelet_node_status.go"
if [ -f "$node_status" ]; then
  # Both the value and the comparison: leaving the comparison against GOOS makes
  # the kubelet decide the label is wrong on every pass and rewrite it forever.
  sed -i '' \
    -e 's|v1.LabelOSStable:      goruntime.GOOS,|v1.LabelOSStable:      ferryContainerOS(),|' \
    -e 's|node.Labels\[v1.LabelOSStable\] = goruntime.GOOS|node.Labels[v1.LabelOSStable] = ferryContainerOS()|' \
    -e 's|osName != goruntime.GOOS|osName != ferryContainerOS()|' \
    "$node_status"
  grep -q 'ferryContainerOS()' "$node_status" \
    || { echo "    !! the node OS label patch did not apply" >&2; exit 1; }
  echo "    ~ pkg/kubelet/kubelet_node_status.go"
fi

# The same question is asked again when a pod is admitted, and answered there
# from GOOS as well -- so a pod that asks for linux was rejected by the node it
# had just been scheduled to, with the API and the scheduler both saying linux
# and the kubelet overruling them.
predicate="$src/pkg/kubelet/lifecycle/predicate.go"
if [ -f "$predicate" ]; then
  sed -i '' \
    -e 's|if !osLabelExists \|\| osName != runtime.GOOS {|if !osLabelExists \|\| osName != ferryContainerOS() {|' \
    -e 's|labels\[v1.LabelOSStable\] = runtime.GOOS|labels[v1.LabelOSStable] = ferryContainerOS()|' \
    "$predicate"
  grep -q 'ferryContainerOS()' "$predicate" \
    || { echo "    !! the admission OS patch did not apply" >&2; exit 1; }
  echo "    ~ pkg/kubelet/lifecycle/predicate.go"
fi

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

# The kubelet only fills in ContainerConfig.Linux -- a container's resource
# limits *and* its security context -- from applyPlatformSpecificContainerConfig,
# which lives behind a linux build tag. On darwin the unsupported variant does
# nothing, so every pod runs with no limits and the default capability set
# whatever its spec says.
#
# The logic is portable: it populates a CRI struct, and the guest is Linux even
# when the host is not. Go derives build constraints from the _linux.go suffix
# as well as the tag, so the tag cannot simply be widened -- the files are copied
# to _darwin.go instead, which also keeps them tracking upstream rather than
# being forked into patches/.
#
# The only parts that genuinely do not apply are three queries about the *host*
# cgroup hierarchy; those are redirected to the shims in ferry_cgroups_darwin.go.
echo "==> deriving darwin container config from the linux implementation"
for f in kuberuntime_container helpers kuberuntime_sandbox; do
  src_file="$src/pkg/kubelet/kuberuntime/${f}_linux.go"
  [ -f "$src_file" ] || continue
  sed -e 's|^//go:build linux$|//go:build darwin|' \
      -e 's|^// +build linux$|// +build darwin|' \
      -e '/libcontainercgroups "github.com\/opencontainers\/cgroups"/d' \
      -e 's|libcontainercgroups\.HugePageSizes()|ferryHugePageSizes()|g' \
      -e 's|libcontainercgroups\.IsCgroup2UnifiedMode()|false|g' \
      -e 's|libcontainercgroups\.ParseCgroupFile("/proc/self/cgroup")|ferryParseCgroupFile()|g' \
      "$src_file" > "$src/pkg/kubelet/kuberuntime/${f}_darwin.go"
  echo "    + ${f}_darwin.go (from ${f}_linux.go)"
done

echo "==> building darwin/arm64 kubelet ($K8S_VERSION)"
cd "$src"
GOFLAGS=-mod=vendor GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 \
  go build -ldflags "$ldflags" -o "$out" ./cmd/kubelet

echo "==> $out"
ls -lh "$out"
