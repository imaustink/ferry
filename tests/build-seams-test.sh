#!/usr/bin/env bash
# Tests for how build-kubelet.sh notices upstream moving under it: the
# constructor signatures each patches/kubelet-vX.Y/ records, and that no seam
# is skipped quietly when its file is missing.
#
# Checks each minor's SIGNATURES against a real tree when one is cached in
# $TMPDIR from an earlier build, and skips that part when none is.
#
#   ./tests/build-seams-test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
# shellcheck source=../lib/overlay.sh
. "$repo/lib/overlay.sh"

pass=0; fail=0; skipped=0
ok()   { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
skip() { skipped=$((skipped + 1)); printf '  - %s (skipped)\n' "$1"; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

printf '\033[1m%s\033[0m\n' "reading a signature"
mkdir -p "$work/tree/pkg/proxy/nftables" "$work/tree/pkg/kubelet/cm" "$work/tree/pkg/kubelet/cadvisor"
cat > "$work/tree/pkg/proxy/nftables/proxier.go" <<'GO'
package nftables

// NewProxier is not this.
func NewProxierFor(x int) {
}

func NewProxier(ctx context.Context,
	ipFamily v1.IPFamily,
	nodeName string,
	initOnly bool,
) (*Proxier, error) {
	return nil, nil
}
GO
got="$(ferry_signature "$work/tree/pkg/proxy/nftables/proxier.go" NewProxier)"
want='func NewProxier(ctx context.Context, ipFamily v1.IPFamily, nodeName string, initOnly bool) (*Proxier, error) {'
if [ "$got" = "$want" ]; then ok "a multi-line argument list comes out on one line"
else bad "a multi-line argument list comes out on one line"; echo "      got  $got"; echo "      want $want"; fi
cat > "$work/reflowed.go" <<'GO'
func NewProxier(ctx context.Context, ipFamily v1.IPFamily,
		nodeName string, initOnly bool) (*Proxier, error) {
GO
[ "$(ferry_signature "$work/reflowed.go" NewProxier)" = "$want" ] \
  && ok "reflowing it is not a change" || bad "reflowing it is not a change"
printf 'func NewContainerManager(ctx context.Context, m mount.Interface) (ContainerManager, error) {\n' \
  > "$work/tree/pkg/kubelet/cm/container_manager_linux.go"
printf 'func New(logger klog.Logger, p ImageFsInfoProvider) (Interface, error) {\n' \
  > "$work/tree/pkg/kubelet/cadvisor/cadvisor_linux.go"

printf '\033[1m%s\033[0m\n' "checking a tree against what was recorded"
ferry_upstream_signatures "$work/tree" > "$work/SIGNATURES"
[ "$(grep -c . "$work/SIGNATURES")" = 3 ] && ok "one line per seam" || bad "one line per seam"
if out="$(ferry_check_signatures "$work/tree" "$work/SIGNATURES")" && [ -z "$out" ]; then
  ok "a tree that matches passes, silently"
else bad "a tree that matches passes, silently"; fi
printf 'func NewContainerManager(ctx context.Context, m mount.Interface, extra bool) (ContainerManager, error) {\n' \
  > "$work/tree/pkg/kubelet/cm/container_manager_linux.go"
if out="$(ferry_check_signatures "$work/tree" "$work/SIGNATURES")"; then
  bad "a moved constructor fails"
else
  ok "a moved constructor fails"
  case "$out" in *"-pkg/kubelet/cm"*"+pkg/kubelet/cm"*"extra bool"*) ok "showing the old and the new side by side" ;;
    *) bad "showing the old and the new side by side"; echo "$out" | sed 's/^/      /' ;; esac
fi
rm "$work/tree/pkg/kubelet/cadvisor/cadvisor_linux.go"
case "$(ferry_upstream_signatures "$work/tree")" in
  *"cadvisor_linux.go:New MISSING"*) ok "a file that has gone says MISSING rather than nothing" ;;
  *) bad "a file that has gone says MISSING rather than nothing" ;; esac

printf '\033[1m%s\033[0m\n' "what each minor records"
for dir in "$repo"/patches/kubelet-v*; do
  mm="$(basename "$dir")"; mm="${mm#kubelet-}"
  sig="$dir/SIGNATURES"
  if [ ! -f "$sig" ]; then bad "$mm has a SIGNATURES"; continue; fi
  if [ "$(grep -c . "$sig")" = 3 ] && ! grep -q MISSING "$sig"; then ok "$mm records all three constructors"
  else bad "$mm records all three constructors"; fi
  # A cached tree from an earlier build, if there is one for this minor.
  tree="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "ferry-kubernetes-$mm.*" 2>/dev/null | sort -V | tail -1)"
  if [ -z "$tree" ]; then skip "$mm against a real tree"; continue; fi
  if ferry_check_signatures "$tree" "$sig" >/dev/null; then ok "$mm matches $(basename "$tree")"
  else bad "$mm matches $(basename "$tree")"; ferry_check_signatures "$tree" "$sig" | sed 's/^/      /'; fi
done

printf '\033[1m%s\033[0m\n' "no seam skipped quietly"
# Every seam goes through seam_file, which fails the build. What is left that
# tests for a file is the one that is conditional by design: knftables'
# netlink.go, which only v1.37's vendored copy has.
quiet="$(grep -nE '^\s*(if )?\[ -f "\$src|\|\| continue$' "$repo/build-kubelet.sh" | grep -v -e netlink -e "&& return 0")"
if [ -z "$quiet" ]; then ok "build-kubelet.sh has no seam behind an if [ -f ]"
else bad "build-kubelet.sh has no seam behind an if [ -f ]"; echo "$quiet" | sed 's/^/      /'; fi
grep -q '^seam_file() {' "$repo/build-kubelet.sh" && ok "and has the check that fails instead" \
  || bad "and has the check that fails instead"

echo
if [ "$fail" -eq 0 ]; then
  [ "$skipped" -gt 0 ] && pass_note=", $skipped skipped"; printf '\033[1m%s\033[0m\n' "$pass passed${pass_note:-}"
else
  printf '\033[1m%s\033[0m\n' "$pass passed, $fail failed"
  exit 1
fi
