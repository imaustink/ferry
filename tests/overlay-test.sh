#!/usr/bin/env bash
# Tests for the darwin sources derived from upstream's linux ones.
#
# The rewrites in lib/overlay.sh are the part of the build most likely to rot,
# and the most dangerous when it does: a rule that stops matching leaves a call
# pointing at the real cm.MilliCPUToShares, which exists on darwin and returns
# 0. That still compiles. The kubelet just goes back to telling the runtime
# every container wants no CPU, and nothing says so.
#
# So this checks both directions -- that the rules rewrite what upstream
# actually writes, and that the checker notices when they do not.
#
#   ./tests/overlay-test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }

contains() { # description file needle
  if grep -qF "$3" "$2"; then ok "$1"; else bad "$1"; echo "      '$3' is not in $2"; fi
}
lacks() { # description file needle
  if grep -qF "$3" "$2"; then bad "$1"; echo "      '$3' is still in $2"; else ok "$1"; fi
}
succeeds() { # description command...
  local description="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$description"; else bad "$description"; fi
}
refuses() { # description command...
  local description="$1"; shift
  if "$@" >/dev/null 2>&1; then bad "$description"; else ok "$description"; fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# shellcheck source=../lib/overlay.sh
. "$repo/lib/overlay.sh"

# A stand-in for kuberuntime_container_linux.go, holding the lines the rules
# have to match. Every one of these is copied from upstream v1.37.0 rather than
# invented, so if upstream changes the shape, this fixture is what gets updated
# alongside the rule.
cat > "$work/sample_linux.go" <<'FIXTURE'
//go:build linux
// +build linux

package kuberuntime

import (
	libcontainercgroups "github.com/opencontainers/cgroups"
	"k8s.io/kubernetes/pkg/kubelet/cm"
)

var isCgroup2UnifiedMode = libcontainercgroups.IsCgroup2UnifiedMode

func example() {
	pageSizes := libcontainercgroups.HugePageSizes()
	unified := libcontainercgroups.IsCgroup2UnifiedMode()
	cgroups, err := libcontainercgroups.ParseCgroupFile("/proc/self/cgroup")
	cpuShares = int64(cm.MilliCPUToShares(cpuLimit.MilliValue()))
	cpuPeriod := int64(cm.QuotaPeriod)
	cpuQuota := cm.MilliCPUToQuota(cpuLimit.MilliValue(), cpuPeriod)
	cm.ApplyPodLevelMemoryHigh(pod, rc, *m.memoryThrottlingFactor)
}
FIXTURE

out="$work/sample_darwin.go"
ferry_derive_darwin_from_linux "$work/sample_linux.go" "$out"

printf '\033[1m%s\033[0m\n' "deriving a darwin file"
contains "the new build tag becomes darwin"  "$out" "//go:build darwin"
contains "and so does the legacy one"        "$out" "// +build darwin"
lacks    "the cgroups import is dropped"     "$out" 'libcontainercgroups "github.com/opencontainers/cgroups"'
contains "hugepages goes to the shim"        "$out" "ferryHugePageSizes()"
contains "the cgroup2 call is answered no"   "$out" "unified := false"
contains "and the cgroup2 function value"    "$out" "= func() bool { return false }"
contains "reading /proc/self/cgroup goes"    "$out" "ferryParseCgroupFile()"
contains "pod memory.high goes to the shim"  "$out" "ferryApplyPodLevelMemoryHigh(pod, rc,"

printf '\033[1m%s\033[0m\n' "the CFS conversions, which fail silently"
contains "shares use ferry's arithmetic"     "$out" "cm.FerryMilliCPUToShares("
contains "quota uses ferry's arithmetic"     "$out" "cm.FerryMilliCPUToQuota("
contains "and the period is ferry's"         "$out" "int64(cm.FerryQuotaPeriod)"
lacks    "no unrewritten shares call"        "$out" "cm.MilliCPUToShares("
lacks    "no unrewritten quota call"         "$out" "cm.MilliCPUToQuota("

printf '\033[1m%s\033[0m\n' "the check that guards all of it"
succeeds "a fully derived file passes"  ferry_check_derived_darwin "$out"

# What rot looks like: upstream renames the helper, the rule stops matching,
# and the call quietly resolves to the zero-returning one.
sed 's|cm\.FerryMilliCPUToShares(|cm.MilliCPUToShares(|' "$out" > "$work/rotted_darwin.go"
refuses "a missed rewrite is caught"    ferry_check_derived_darwin "$work/rotted_darwin.go"

sed 's|ferryHugePageSizes()|libcontainercgroups.HugePageSizes()|' "$out" > "$work/cgroups_darwin.go"
refuses "so is a leftover cgroups call" ferry_check_derived_darwin "$work/cgroups_darwin.go"

sed 's|ferryApplyPodLevelMemoryHigh(|cm.ApplyPodLevelMemoryHigh(|' "$out" > "$work/memhigh_darwin.go"
refuses "and a missed memory.high call"  ferry_check_derived_darwin "$work/memhigh_darwin.go"

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[1m%d passed\033[0m\n' "$pass"
else
  printf '\033[1m%d passed, %d failed\033[0m\n' "$pass" "$fail"
  exit 1
fi
