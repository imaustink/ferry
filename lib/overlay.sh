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

# The substitutions, and what each is for.
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
# CpuQuota of 0 and its CPU limit never sized the VM. cm.Ferry* in
# ferry_cpu_conversions_darwin.go does the real arithmetic.
ferry_derive_darwin_from_linux() { # source-linux-file destination-darwin-file
  sed -e 's|^//go:build linux$|//go:build darwin|' \
      -e 's|^// +build linux$|// +build darwin|' \
      -e '/libcontainercgroups "github.com\/opencontainers\/cgroups"/d' \
      -e 's|libcontainercgroups\.HugePageSizes()|ferryHugePageSizes()|g' \
      -e 's|libcontainercgroups\.IsCgroup2UnifiedMode()|false|g' \
      -e 's|= libcontainercgroups\.IsCgroup2UnifiedMode$|= func() bool { return false }|' \
      -e 's|libcontainercgroups\.ParseCgroupFile("/proc/self/cgroup")|ferryParseCgroupFile()|g' \
      -e 's|cm\.ApplyPodLevelMemoryHigh(|ferryApplyPodLevelMemoryHigh(|g' \
      -e 's|cm\.MilliCPUToShares(|cm.FerryMilliCPUToShares(|g' \
      -e 's|cm\.MilliCPUToQuota(|cm.FerryMilliCPUToQuota(|g' \
      -e 's|cm\.QuotaPeriod|cm.FerryQuotaPeriod|g' \
      "$1" > "$2"
}

# Nothing upstream may still be named in a derived file.
#
# The two halves fail differently, and the second is why this exists as a check
# rather than being left to the compiler.
#
# libcontainercgroups: the import is deleted unconditionally, so every use of it
# has to have been rewritten -- one survivor is an `undefined:
# libcontainercgroups` at build time with nothing naming the seam that missed.
# Asserting on the package rather than on one substitution is also what makes
# this survive upstream moving between the two forms, as it did in v1.35: v1.34
# calls IsCgroup2UnifiedMode(), v1.35 and v1.36 assign the function itself.
#
# The CFS conversions: a survivor here compiles perfectly well, because
# cm.MilliCPUToShares does exist on darwin. It just returns 0, and the kubelet
# goes back to telling the runtime that every container wants no CPU. Nothing
# says so, at build time or after. That silence is the whole reason to check.
#
# Prints what it found, and returns non-zero if it found anything.
ferry_check_derived_darwin() { # darwin-file
  # Fixed strings, not expressions: these end in an open parenthesis, which a
  # regex reads as the start of a group. None is a prefix of its own
  # replacement -- cm.MilliCPUToShares( does not occur inside
  # cm.FerryMilliCPUToShares( -- so a substring search is exact here.
  local file="$1" found=0 name
  for name in \
    'libcontainercgroups.' \
    'cm.MilliCPUToShares(' \
    'cm.MilliCPUToQuota(' \
    'cm.QuotaPeriod' \
    'cm.ApplyPodLevelMemoryHigh('; do
    if grep -qF "$name" "$file"; then
      echo "$(basename "$file"): still names $name"
      grep -nF "$name" "$file"
      found=1
    fi
  done
  return "$found"
}
