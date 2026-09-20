#!/usr/bin/env bash
# Builds a darwin/arm64 kubelet from upstream Kubernetes with the ferry patch
# overlay applied. Patches are kept as whole files under patches/kubelet/
# mirroring the upstream tree, plus build-tag edits below -- diffs against a
# tree this large rot too fast to be worth maintaining.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
FERRY_ROOT="$here"
export FERRY_ROOT
# shellcheck source=lib/versions.sh
. "$here/lib/versions.sh"

K8S_VERSION="${K8S_VERSION:-v1.34.0}"
ferry_version_valid "$K8S_VERSION" \
  || { echo "K8S_VERSION=$K8S_VERSION is not a version like v1.34.0" >&2; exit 1; }
# A few shims differ by minor -- upstream changes a constructor's signature and
# the darwin stand-in has to match. Those live in patches/kubelet-vX.Y/ and are
# laid over the shared tree, so supporting a new minor does not mean forking the
# whole overlay or breaking the one before it.
#
# Checked before anything is cloned. Without this directory nothing declares
# cadvisor.New or cm.NewContainerManager, so the build would clone, retag and
# derive and then die minutes later in a wall of `undefined:` errors that say
# nothing about the missing directory. Every other seam in this script that
# cannot be satisfied stops at the point it is noticed.
overlay="$here/patches/kubelet-$(ferry_version_mm "$K8S_VERSION")"
if [ ! -d "$overlay" ]; then
  echo "no per-minor overlay at patches/kubelet-$(ferry_version_mm "$K8S_VERSION")/" >&2
  echo "It carries the shims whose signatures move between minors -- cadvisor.New" >&2
  echo "and cm.NewContainerManager. Copy the nearest minor's and fix the signatures" >&2
  echo "against upstream's linux implementations for $K8S_VERSION." >&2
  exit 1
fi

src="${K8S_SRC:-${TMPDIR:-/tmp}/ferry-kubernetes-$K8S_VERSION}"
# Built into the version store, not over bin/kubelet. Building the version you
# are currently running is an ordinary thing to do during an upgrade, and
# writing over a mapped binary is what leaves it killed at launch forever.
out="$(ferry_version_dir "$K8S_VERSION")/kubelet"
mkdir -p "$(dirname "$out")"

if [ ! -d "$src" ]; then
  echo "==> cloning kubernetes $K8S_VERSION"
  git clone --depth 1 --branch "$K8S_VERSION" --single-branch \
    https://github.com/kubernetes/kubernetes.git "$src"
else
  echo "==> reusing source at $src"
  git -C "$src" checkout -- . 2>/dev/null || true
  # checkout restores what upstream tracks; every file the overlay adds is
  # untracked, so it survives. That matters now that the per-minor shims are
  # separate files: a tree built from a checkout that carried
  # ferry_new_darwin.go, reused by one whose cadvisor_darwin.go still declares
  # New itself, fails on a redeclaration with nothing pointing at the leftover.
  # Sweep them so the overlay is always exactly what this checkout says.
  git -C "$src" clean -fdq 2>/dev/null || true
fi

echo "==> applying overlay"
(cd "$here/patches/kubelet" && find . -name '*.go' -print0) \
  | while IFS= read -r -d '' f; do
      # Make the parent first: a patch may add a directory upstream does not
      # have -- cmd/ferry-proxyd is ferry's own -- and BSD install will not
      # create it, so a fresh clone failed here.
      mkdir -p "$(dirname "$src/$f")"
      install -m 0644 "$here/patches/kubelet/$f" "$src/$f"
      echo "    + ${f#./}"
    done

echo "==> overlaying $(basename "$overlay")"
(cd "$overlay" && find . -name '*.go' -print0) \
  | while IFS= read -r -d '' f; do
      mkdir -p "$(dirname "$src/$f")"
      install -m 0644 "$overlay/$f" "$src/$f"
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
      -e 's|= libcontainercgroups\.IsCgroup2UnifiedMode$|= func() bool { return false }|' \
      -e 's|libcontainercgroups\.ParseCgroupFile("/proc/self/cgroup")|ferryParseCgroupFile()|g' \
      "$src_file" > "$src/pkg/kubelet/kuberuntime/${f}_darwin.go"
  # The import is deleted unconditionally, so every use of it has to have been
  # rewritten -- one survivor is an `undefined: libcontainercgroups` at build
  # time with nothing naming the seam that missed. Asserting on the package
  # rather than on one substitution is also what makes this survive upstream
  # moving between the two forms, as it did in v1.35: v1.34 calls
  # IsCgroup2UnifiedMode(), v1.35 and v1.36 assign the function itself.
  ! grep -q 'libcontainercgroups\.' "$src/pkg/kubelet/kuberuntime/${f}_darwin.go" \
    || { echo "    !! ${f}_darwin.go still reaches for libcontainercgroups, whose import was just removed:" >&2
         grep -n 'libcontainercgroups\.' "$src/pkg/kubelet/kuberuntime/${f}_darwin.go" >&2
         echo "    upstream moved a cgroup call this script rewrites; add a seam for it above" >&2
         exit 1; }
  echo "    + ${f}_darwin.go (from ${f}_linux.go)"
done

echo "==> building darwin/arm64 kubelet ($K8S_VERSION)"
cd "$src"
# cgo is on because the node's CPU usage has no other source. macOS publishes no
# kern.cp_time and no /proc/stat, so cumulative machine CPU comes from the Mach
# host port, and that is a C call. Without it node_cpu_usage_seconds_total is
# zero, metrics-server drops the node, and `kubectl top nodes` fails while
# `kubectl top pods` works. This builds on the Mac that will run it, so the C
# toolchain is the one already installed for Swift.
rm -f "$out"
GOFLAGS=-mod=vendor GOOS=darwin GOARCH=arm64 CGO_ENABLED=1 \
  go build -ldflags "$ldflags" -o "$out" ./cmd/kubelet

echo "==> $out"
ls -lh "$out"
