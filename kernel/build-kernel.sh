#!/usr/bin/env bash
# Builds a guest kernel with NAT support.
#
# The default guest kernel comes from kata-containers, which ships netfilter
# without the NAT extensions:
#
#     iptables -t nat -A ...
#       Warning: Extension DNAT revision 0 not supported, missing kernel module?
#     /proc/net/ip_tables_names -> no nat table
#
# and the kernel is monolithic, so nothing can be loaded at runtime. Without NAT
# a pod cannot program Service rules in its own kernel, which is what forces
# ClusterIP routing onto the host and with it the root requirement and the extra
# hop through the Mac.
#
# Apple's own kernel configuration does enable it -- CONFIG_NF_NAT,
# CONFIG_NF_CONNTRACK, CONFIG_NF_NAT_MASQUERADE, CONFIG_NF_TABLES -- so this
# builds that configuration rather than inventing one. The build runs in a
# Linux container because it needs a cross toolchain, and ferry now hosts
# that itself: the toolchain image is built with `ferry image build`, the
# same buildkit-in-a-pod path `docs/RUNTIMES.md#building-an-image-without-docker`
# documents, and the actual compile runs in a one-shot pod against this
# directory's own .build/stage over a hostPath volume -- the pod equivalent
# of `docker run -v`. Needs a running cluster (`ferry up`); nothing here
# talks to Docker.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# The exact ferry this checkout builds with, not whatever version happens to
# be on PATH -- an older installed release would not have --export/--no-load
# on 'ferry image build', and cmd_kernel always execs this script from a
# checkout's own $here/kernel, so the sibling ferry is always the right one.
FERRY="${FERRY:-$here/../ferry}"
CONTAINERIZATION_REF="${CONTAINERIZATION_REF:-0.45.0}"
KERNEL_SOURCE="${KERNEL_SOURCE:-https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.5.tar.xz}"
# OUT and CONFIG_FRAGMENT build a variant without touching the kernel ferry
# boots: a fragment's lines are appended to Apple's configuration, and
# olddefconfig lets a later assignment win over the earlier one.
out="${OUT:-$here/vmlinux-arm64}"
work="$here/.build"

# The kernel ferry boots records what it was built from, and a kernel built
# from other patches or configuration is rebuilt rather than kept. A variant
# (OUT or CONFIG_FRAGMENT) records nothing, being nobody's default.
# shellcheck source=../lib/versions.sh
. "$here/../lib/versions.sh"
record=""
if [ -z "${OUT:-}" ] && [ -z "${CONFIG_FRAGMENT:-}" ]; then
  record="$(FERRY_ROOT="$here/.." ferry_kernel_inputs)"
fi
if [ -f "$out" ] && [ "${FORCE:-}" != "1" ]; then
  if [ -z "$record" ] || [ "$record" = "$(cat "$out.inputs" 2>/dev/null || true)" ]; then
    echo "==> kernel present: $out (FORCE=1 to rebuild)"
    exit 0
  fi
  echo "==> $out was built from other patches or configuration; rebuilding"
fi

[ -x "$FERRY" ] || { echo "$FERRY not found or not executable -- run this from a checkout" >&2; exit 1; }
command -v buildctl >/dev/null || { echo "buildctl is required to build the kernel toolchain image (brew install buildkit)" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl is required to run the kernel build (brew install kubectl, or 'ferry doctor')" >&2; exit 1; }
: "${KUBECONFIG:=$HOME/.ferry/admin.conf}"
export KUBECONFIG
kubectl get nodes >/dev/null 2>&1 || { echo "no cluster reachable -- run 'ferry up' first" >&2; exit 1; }

# The pod that does the actual compiling needs real CPU, or it inherits a
# pod's default 2 vCPUs and takes hours over minutes -- the same sizing
# lesson experiment 25 paid for with the buildkit builder. Half the Mac by
# default, matching FERRY_BUILDER_CPUS' own default (docs/INSTALL.md).
KERNEL_BUILD_CPUS="${KERNEL_BUILD_CPUS:-$(( $(sysctl -n hw.ncpu) / 2 ))}"
[ "$KERNEL_BUILD_CPUS" -ge 2 ] || KERNEL_BUILD_CPUS=2
KERNEL_BUILD_MEMORY="${KERNEL_BUILD_MEMORY:-8Gi}"

mkdir -p "$work"

# Take the configuration and build recipe from Apple's repository rather than
# vendoring them, so the kernel tracks what the framework expects.
if [ ! -d "$work/containerization" ]; then
  echo "==> fetching containerization $CONTAINERIZATION_REF for its kernel config"
  git clone --depth 1 --branch "$CONTAINERIZATION_REF" \
    https://github.com/apple/containerization.git "$work/containerization" 2>&1 | tail -1
fi
src="$work/containerization/kernel"
[ -f "$src/config-arm64" ] || { echo "no kernel config in $src" >&2; exit 1; }

echo "==> confirming the configuration actually enables NAT"
for symbol in CONFIG_NF_NAT CONFIG_NF_CONNTRACK CONFIG_NF_TABLES CONFIG_NF_NAT_MASQUERADE; do
  if grep -q "^${symbol}=y" "$src/config-arm64"; then
    printf '    %-28s y\n' "$symbol"
  else
    echo "    $symbol MISSING -- this kernel would not fix Services" >&2
    exit 1
  fi
done

if [ ! -f "$work/source.tar.xz" ]; then
  echo "==> downloading $(basename "$KERNEL_SOURCE")"
  curl -fSL --progress-bar -o "$work/source.tar.xz" "$KERNEL_SOURCE"
fi

echo "==> building the toolchain image"
"$FERRY" image build -t ferry-kernel-build:1 --quiet "$src/image"

echo "==> compiling (this takes a while)"
stage="$work/stage"
rm -rf "$stage"; mkdir -p "$stage"
cp "$src/config-arm64" "$src/build.sh" "$stage/"
# USB mass storage, always: the one way a disk reaches a VM that is already
# running, which is how a ferry-local-block claim reaches a machine. Nine
# symbols, and they cost a pod VM nothing measurable -- the drivers probe only
# when there is a USB controller, and only machines are given one (experiment
# 33).
echo "==> adding usb-storage.config"
{ echo; cat "$here/usb-storage.config"; } >> "$stage/config-arm64"
# What a pod VM has no use for, taken out of every build: see slim.config.
{ echo; cat "$here/slim.config"; } >> "$stage/config-arm64"
if [ -n "${CONFIG_FRAGMENT:-}" ]; then
  echo "==> adding $(basename "$CONFIG_FRAGMENT")"
  { echo; cat "$CONFIG_FRAGMENT"; } >> "$stage/config-arm64"
fi
cp "$work/source.tar.xz" "$stage/"
# ferry's own patches, applied between Apple's unpack and Apple's make. Their
# build.sh has no hook there, so one is spliced in after the line that copies
# the configuration, and the build stops if that line has moved. git rather
# than patch because the toolchain image has one and not the other.
mkdir -p "$stage/patches"
cp "$here"/patches/*.patch "$stage/patches/"
anchor='cp "/kernel/${CONFIG}" /kbuild/.config'
grep -qF "$anchor" "$stage/build.sh" || { echo "Apple's build.sh has changed; cannot place ferry's patches" >&2; exit 1; }
hook='for p in /kernel/patches/*.patch; do echo "==> applying ${p##*/}"; git -C /kbuild apply -p1 "$p" || exit 1; done'
while IFS= read -r line; do
  printf '%s\n' "$line"
  [ "$line" = "$anchor" ] && printf '%s\n' "$hook"
done < "$stage/build.sh" > "$stage/build-ferry.sh"

# A pod in place of 'docker run -v'. hostPath is ferry's own bind mount --
# what the pod writes into /kernel lands directly in $stage on the Mac, the
# same round-trip-free arrangement -v gave. restartPolicy: Never and a
# resources.limits are what make it a one-shot job sized for real work
# instead of a pod's default 2 vCPUs / 512 MiB (docs/GAPS.md's Volumes and
# images section covers hostPath support).
pod="ferry-kernel-build-$$"
trap 'kubectl delete pod "$pod" --ignore-not-found >/dev/null 2>&1 || true' EXIT
cat > "$work/pod.yaml" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  labels: {app: ferry-kernel-build}
spec:
  restartPolicy: Never
  containers:
    - name: build
      image: ferry-kernel-build:1
      imagePullPolicy: IfNotPresent
      workingDir: /kernel
      command: ["bash", "/kernel/build-ferry.sh"]
      env:
        - {name: TARGET_ARCH, value: "arm64"}
        - {name: LOCALVERSION, value: "-ferry"}
      resources:
        limits: {cpu: "$KERNEL_BUILD_CPUS", memory: "$KERNEL_BUILD_MEMORY"}
      volumeMounts:
        - {name: kernel, mountPath: /kernel}
  volumes:
    - name: kernel
      hostPath: {path: "$stage", type: Directory}
YAML

echo "==> compiling in a pod ($KERNEL_BUILD_CPUS vCPUs, $KERNEL_BUILD_MEMORY) -- this takes a while"
kubectl apply -f "$work/pod.yaml" >/dev/null

# kubectl logs -f blocks until the container exits and streams its output
# meanwhile, the same visibility 'docker run' without -d already gave; it
# just needs a container to attach to first.
for _ in $(seq 120); do
  phase="$(kubectl get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [ "$phase" = "Pending" ] || break
  sleep 1
done
kubectl logs -f "$pod" --container=build 2>&1 || true

# A pod's phase can lag a few seconds behind its container actually exiting
# (logs -f returning is not the same event), so this polls briefly instead
# of trusting a single read right after the stream ends.
phase=""
for _ in $(seq 30); do
  phase="$(kubectl get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  case "$phase" in Succeeded|Failed) break ;; esac
  sleep 1
done
if [ "$phase" != "Succeeded" ]; then
  echo "kernel build pod ended $phase" >&2
  kubectl describe pod "$pod" 2>&1 | tail -20 >&2
  exit 1
fi

[ -f "$stage/vmlinux-arm64" ] || { echo "build produced no kernel" >&2; exit 1; }
install -m 0644 "$stage/vmlinux-arm64" "$out"
rm -f "$out.inputs"
[ -n "$record" ] && echo "$record" > "$out.inputs"
rm -rf "$stage"

echo "==> $out"
file "$out"
