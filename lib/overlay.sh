#!/usr/bin/env bash
# Deriving darwin sources from upstream's linux ones.
#
# Sourced by build-kubelet.sh, which does the deriving, and by
# tests/overlay-test.sh, which checks the rewrites still match the shapes
# upstream writes. It is here rather than inline in the build so those two
# cannot disagree: a test carrying its own copy of the rules would pass forever
# while the build rewrote nothing.
#
# Why rewrite rather than fork the files into patches/: the logic in
# kuberuntime's linux files populates a CRI struct, and the guest is Linux even
# when the host is not, so nearly all of it is already right. Go derives build
# constraints from the _linux.go suffix as well as from the tag, so the tag
# cannot simply be widened -- the file has to be copied to a _darwin.go name.
# Copying with a handful of substitutions keeps the result tracking upstream
# instead of freezing a fork of it.

# The rules. One per line: the name that must not survive in a derived file,
# a space, and the sed expression that rewrites it.
#
# Both halves of this file read this one table, because they were two lists
# before and two lists drift. A rewrite added without its assertion is a seam
# nobody is watching, which is the exact failure the assertions exist to catch.
#
# A guard of `-` is a rewrite with nothing to assert on. The build tags are not
# a seam: a file that failed to be retagged is not compiled at all rather than
# compiled wrong, so the compiler already says so.
#
# Several rules share the libcontainercgroups guard on purpose. The assertion is
# on the package rather than on any one call, which is what makes it survive
# upstream moving between forms, as it did in v1.35: v1.34 calls
# IsCgroup2UnifiedMode(), v1.35 and v1.36 assign the function itself. Repeated
# guards are collapsed.
#
# What each rule is for:
#
# The host-cgroup queries -- HugePageSizes, IsCgroup2UnifiedMode,
# ParseCgroupFile -- describe macOS, which has no cgroups, so they are answered
# in the negative. ApplyPodLevelMemoryHigh, called from v1.37, joins them: it
# writes memory.high to a pod cgroup, and ferry's pod boundary is a VM.
#
# The CFS conversions are the opposite case. They do apply, because the numbers
# land in a Linux kernel inside the pod's VM, but on darwin package cm compiles
# helpers_unsupported.go, where every CFS constant is 0 and both conversions
# return 0. Left alone, every container reached the runtime with CpuShares and
# CpuQuota of 0. cm.Ferry* in ferry_cpu_conversions_darwin.go does the real
# arithmetic.
ferry_overlay_rules=(
  '- s|^//go:build linux$|//go:build darwin|'
  '- s|^// +build linux$|// +build darwin|'
  'libcontainercgroups. /libcontainercgroups "github.com\/opencontainers\/cgroups"/d'
  'libcontainercgroups. s|libcontainercgroups\.HugePageSizes()|ferryHugePageSizes()|g'
  'libcontainercgroups. s|libcontainercgroups\.IsCgroup2UnifiedMode()|false|g'
  'libcontainercgroups. s|= libcontainercgroups\.IsCgroup2UnifiedMode$|= func() bool { return false }|'
  'libcontainercgroups. s|libcontainercgroups\.ParseCgroupFile("/proc/self/cgroup")|ferryParseCgroupFile()|g'
  'cm.ApplyPodLevelMemoryHigh( s|cm\.ApplyPodLevelMemoryHigh(|ferryApplyPodLevelMemoryHigh(|g'
  'cm.MilliCPUToShares( s|cm\.MilliCPUToShares(|cm.FerryMilliCPUToShares(|g'
  'cm.MilliCPUToQuota( s|cm\.MilliCPUToQuota(|cm.FerryMilliCPUToQuota(|g'
  'cm.QuotaPeriod s|cm\.QuotaPeriod|cm.FerryQuotaPeriod|g'
  'cm.MinShares s|cm\.MinShares|cm.FerryMinShares|g'
  'cm.MinMilliCPULimit s|cm\.MinMilliCPULimit|cm.FerryMinMilliCPULimit|g'
)

# The names no derived file may still contain, one per line, in table order and
# without repeats. Read by ferry_check_derived_darwin, and by the test, which
# reintroduces each one in turn to prove the check would notice.
ferry_overlay_guards() {
  local rule guard seen existing
  local -a guards=()
  for rule in "${ferry_overlay_rules[@]}"; do
    guard="${rule%% *}"
    if [ "$guard" = "-" ]; then continue; fi
    seen=0
    for existing in ${guards[@]+"${guards[@]}"}; do
      if [ "$existing" = "$guard" ]; then seen=1; break; fi
    done
    if [ "$seen" -eq 0 ]; then
      guards+=("$guard")
      echo "$guard"
    fi
  done
}

ferry_derive_darwin_from_linux() { # source-linux-file destination-darwin-file
  local rule
  local -a args=()
  for rule in "${ferry_overlay_rules[@]}"; do
    args+=(-e "${rule#* }")
  done
  sed "${args[@]}" "$1" > "$2"
}

# The same rules, applied to a file that stays where it is.
#
# Most of what package cm gets wrong on darwin is reached from the kuberuntime
# files, which are derived and so get a _darwin.go of their own. kubelet_pods.go
# is not: it carries no build tag, so there is one copy and it is compiled here
# as written. It still names cm.MinShares and cm.MinMilliCPULimit -- Linux
# floors that helpers_unsupported.go declares as 0 -- to decide what a
# container's status reports, and from v1.37 it names cm.MilliCPUToShares too.
#
# Rewriting it in place rather than copying it is the same bargain
# build-kubelet.sh already takes with kubelet_node_status.go and predicate.go:
# the tree is darwin-only and thrown away, and `git checkout -- .` on reuse puts
# the file back. Rules that match nothing leave it alone, so the build tag rules
# and the cgroup ones are no-ops here.
ferry_rewrite_darwin_in_place() { # file
  local tmp="$1.ferry-rewriting"
  ferry_derive_darwin_from_linux "$1" "$tmp" && mv "$tmp" "$1"
}

# Nothing upstream may still be named in a derived file.
#
# The two halves fail differently, and the second is why this exists as a check
# rather than being left to the compiler.
#
# libcontainercgroups: the import is deleted unconditionally, so every use of it
# has to have been rewritten -- one survivor is an `undefined:
# libcontainercgroups` at build time with nothing naming the seam that missed.
#
# The CFS conversions: a survivor here compiles perfectly well, because
# cm.MilliCPUToShares does exist on darwin. It just returns 0, and the kubelet
# goes back to telling the runtime that every container wants no CPU. Nothing
# says so, at build time or after. That silence is the whole reason to check.
#
# Prints what it found, and returns non-zero if it found anything.
ferry_check_derived_darwin() { # darwin-or-rewritten-file
  # Fixed strings, not expressions: these end in an open parenthesis, which a
  # regex reads as the start of a group. None is a prefix of its own
  # replacement -- cm.MilliCPUToShares( does not occur inside
  # cm.FerryMilliCPUToShares( -- so a substring search is exact here.
  local file="$1" found=0 guard
  while IFS= read -r guard; do
    if grep -qF "$guard" "$file"; then
      echo "$(basename "$file"): still names $guard"
      grep -nF "$guard" "$file"
      found=1
    fi
  done < <(ferry_overlay_guards)
  return "$found"
}

# --- pacing that is upstream's default and not ferry's ---------------------

# Shorten the volume manager's poll intervals, in place.
#
# A pod whose only volume is its projected serviceaccount token waits 301ms
# between "Waiting for volumes to attach and mount" and "All volumes are
# attached and mounted", and 10ms of that is the mount. The rest is three
# sleeps: the populator's loop notices the volume, the reconciler's next tick
# verifies it, the tick after that mounts it. Measured with the kubelet's own
# --v=4 log in experiments/24-benchmark-harness (syncphases.py); kind measures
# 301ms too, so this is upstream's pacing rather than anything ferry does.
#
# Upstream's numbers suit a node reconciling hundreds of pods with
# network-attached volumes, where a tighter loop is real work against an API
# server and a cloud provider. A ferry node is one developer's machine with
# local volumes, and the same loop is three sleeps on the critical path of
# every pod start -- worth 279ms of a 710ms pod on the measurement that
# prompted this.
#
# Here rather than in build-kubelet.sh because the guest kubelet mode 2 boots
# wants exactly the same rewrite and none of the darwin overlay around it.
ferry_shorten_volume_polls() { # kubernetes-source-dir
  local f="$1/pkg/kubelet/volumemanager/volume_manager.go"
  [ -f "$f" ] || { echo "no $f" >&2; return 1; }

  # Each is "name = <n> * time.Millisecond" on one line, tab-indented inside a
  # const block. Anchored on the name so a duration elsewhere cannot be caught
  # by accident, and [[:space:]] rather than \t because BSD sed does not read
  # \t as a tab in a pattern -- it matches nothing and leaves the build quietly
  # at upstream's pacing. Indentation comes back through the capture group.
  #
  # [0-9]* on the left makes this idempotent: the source tree is reused between
  # builds, so this runs again over numbers it already wrote.
  sed -i '' \
    -e "s/^\([[:space:]]*reconcilerLoopSleepPeriod *= *\)[0-9]* \* time.Millisecond/\1${FERRY_VOLUME_RECONCILE_MS:-10} * time.Millisecond/" \
    -e "s/^\([[:space:]]*desiredStateOfWorldPopulatorLoopSleepPeriod *= *\)[0-9]* \* time.Millisecond/\1${FERRY_VOLUME_POPULATE_MS:-10} * time.Millisecond/" \
    -e "s/^\([[:space:]]*podAttachAndMountRetryInterval *= *\)[0-9]* \* time.Millisecond/\1${FERRY_VOLUME_RETRY_MS:-20} * time.Millisecond/" \
    "$f"

  # Verified rather than assumed. A constant upstream renames, moves, or
  # respells as `time.Duration(100) * time.Millisecond` leaves the sed matching
  # nothing and the build silently back at upstream's pacing -- a regression
  # with nothing anywhere pointing at it.
  local want
  for want in \
    "reconcilerLoopSleepPeriod = ${FERRY_VOLUME_RECONCILE_MS:-10} \* time.Millisecond" \
    "desiredStateOfWorldPopulatorLoopSleepPeriod = ${FERRY_VOLUME_POPULATE_MS:-10} \* time.Millisecond" \
    "podAttachAndMountRetryInterval = ${FERRY_VOLUME_RETRY_MS:-20} \* time.Millisecond"; do
    grep -qE "$want" "$f" || {
      echo "could not set: $want" >&2
      echo "upstream moved or respelled it; see ferry_shorten_volume_polls" >&2
      return 1; }
  done
}
