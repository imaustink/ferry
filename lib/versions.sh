#!/usr/bin/env bash
# ferry's version store.
#
# Sourced by ferry, build-kubelet.sh and control-plane/fetch-binaries.sh, which
# all need the same answers to the same two questions: which Kubernetes this
# cluster is, and where the binaries for it live.
#
# Before this existed the answers disagreed. The kubelet was built from
# K8S_VERSION (v1.34.0) and the control plane was downloaded at a default of its
# own (v1.34.11) that nothing passed through, so `--kubernetes-version` moved
# one half of the cluster and left the other where it was. Asking for a version
# newer than the control plane's default produced a kubelet newer than the API
# server, which is unsupported skew, with nothing anywhere saying so.
#
# So one version is chosen, and everything Kubernetes-versioned is stored under
# it:
#
#   bin/versions/v1.34.0/{kubelet,ferry-proxyd,kube-apiserver,...}
#   bin/versions/v1.34.0/MANIFEST
#   bin/kubelet -> versions/v1.34.0/kubelet
#
# ferry's own binaries -- ferry-cri, ferry-cni, the daemons -- are not in the
# store. They are this checkout's code, not Kubernetes', and rolling the cluster
# back to an older Kubernetes should not roll back the runtime with it.
#
# The indirection is a symlink rather than a copy for two reasons. Rollback
# becomes a flip rather than a rebuild. And nothing is ever written over a
# binary that is running -- which on macOS leaves that file permanently
# unrunnable, killed at launch with a bare "Killed: 9" and a signature that
# still verifies. cmd_doctor has a check for exactly that failure; the store is
# built so it cannot happen here.

# Everything whose version is Kubernetes' to decide.
FERRY_VERSIONED_BINARIES="kubelet ferry-proxyd kube-apiserver kube-controller-manager kube-scheduler etcd etcdctl etcdutl"
# The subset the control plane starts. Used when only those have to move.
# shellcheck disable=SC2034 # read by ferry, which sources this file
FERRY_CONTROL_PLANE_BINARIES="kube-apiserver kube-controller-manager kube-scheduler etcd etcdctl etcdutl"

# The Kubernetes a checkout builds when nothing says otherwise.
#
# Held here rather than in each caller because ferry, build-kubelet.sh,
# control-plane/fetch-binaries.sh and control-plane/up.sh all used to spell the
# same literal separately. That is the disagreement this file exists to end: a
# default bumped in three of those four places is the split-version bug in the
# header above, arrived at from the other direction.
#
# It has to be a minor ferry_control_plane_version pins, or a fresh checkout's
# first build asks kwok-ci for a control plane nobody published.
#
# Note this is only where a *new* checkout starts. ferry prefers
# ferry_active_version, so a checkout that has already built something stays
# where it is until someone asks it to move -- bumping this never upgrades an
# existing cluster behind its back, and could not: ferry_skew_reason still
# refuses to cross more than one minor at a time.
# shellcheck disable=SC2034 # read by the four scripts that source this file
FERRY_DEFAULT_K8S_VERSION="v1.37.0"

# --- version arithmetic ---------------------------------------------------

ferry_version_valid() { # vX.Y.Z
  local rest="${1#v}"
  case "${1:-}" in
    v[0-9]*) : ;;
    *) return 1 ;;
  esac
  # Every field a number, and exactly three of them. The glob alone accepts
  # v1.34.x, which is not a version.
  case "$rest" in
    *[!0-9.]*) return 1 ;;
  esac
  [ "$(printf '%s' "$rest" | tr -cd . | wc -c | tr -d ' ')" = 2 ]
}

ferry_version_major() { printf '%s' "${1#v}" | cut -d. -f1; }
ferry_version_minor() { printf '%s' "${1#v}" | cut -d. -f2; }
ferry_version_patch() { printf '%s' "${1#v}" | cut -d. -f3; }
# major.minor, which is the unit Kubernetes' own compatibility rules speak in.
ferry_version_mm() { echo "v$(ferry_version_major "$1").$(ferry_version_minor "$1")"; }

# --- what each Kubernetes version is paired with --------------------------

# The control plane ferry runs for a given Kubernetes version.
#
# Upstream publishes no darwin build of the control plane, so these come from
# kwok-ci/k8s, which does not build every patch release. The kubelet is compiled
# here from any tag that exists; the control plane can only be a tag kwok-ci
# happens to have published. Pinning one per minor keeps that mismatch visible
# and legal -- a v1.34.11 API server with a v1.34.0 kubelet is the same minor,
# which is well inside the supported skew -- rather than silently 404ing at
# download time.
#
# v1.34 through v1.37 have been built. The rest are the shape this takes when
# another minor is added, not a claim that they work.
#
# The pins have to be an unbroken ladder, because ferry_skew_reason below refuses
# to skip a minor: a v1.36 pinned with no v1.35 under it is a v1.36 no existing
# cluster can reach, only a fresh one. So v1.35 is pinned even though nothing
# wants to stop there for its own sake. It needs a kubelet overlay of its own --
# by v1.35 NewContainerManager has taken a context but cadvisor.New has not yet
# taken a logger, so neither neighbour's shims compile against it.
#
# v1.37 was thought to be unbuildable, on the grounds that upstream had removed
# the vendored cadvisor packages the darwin shim imports. They were not removed:
# cadvisor folded info/v1 and info/v2 into a single lib/model package, which
# k8s.io/kubernetes v1.37.0 vendors, and kubelet's own cadvisor.Interface is
# declared in terms of it. So the shim could not have kept its own copy of the
# old packages either -- it has to speak the types the Interface names. It is a
# rename, and patches/kubelet-v1.37/ carries it.
ferry_control_plane_version() { # k8s-version
  [ -n "${K8S_CONTROL_PLANE_VERSION:-}" ] && { echo "$K8S_CONTROL_PLANE_VERSION"; return; }
  case "$(ferry_version_mm "$1")" in
    v1.34) echo "v1.34.11" ;;
    v1.35) echo "v1.35.8" ;;
    v1.36) echo "v1.36.4" ;;
    v1.37) echo "v1.37.0" ;;
    # No pin for this minor: ask for the exact version and let the download say
    # so if kwok-ci has not built it. The error names the override.
    *)     echo "$1" ;;
  esac
}

# The etcd a given Kubernetes version expects.
#
# These are upstream's own pairings. The one that matters for upgrades is that
# 1.33 and 1.34 are on different etcd *minors*: moving between them migrates the
# data directory, and etcd does not support going back down without restoring a
# snapshot. `ferry upgrade` says so before it does it, and keeps the snapshot.
ferry_etcd_version() { # k8s-version
  [ -n "${ETCD_VERSION:-}" ] && { echo "$ETCD_VERSION"; return; }
  case "$(ferry_version_mm "$1")" in
    v1.31) echo "v3.5.15" ;;
    v1.32) echo "v3.5.16" ;;
    v1.33) echo "v3.5.21" ;;
    *)     echo "v3.6.5" ;;
  esac
}

# --- the store ------------------------------------------------------------

# The checkout root. Callers that know it set FERRY_ROOT; otherwise this file
# sits one directory below it.
ferry_root() {
  if [ -n "${FERRY_ROOT:-}" ]; then echo "$FERRY_ROOT"; return; fi
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

ferry_bin_dir()      { echo "$(ferry_root)/bin"; }
ferry_versions_dir() { echo "$(ferry_root)/bin/versions"; }
ferry_version_dir()  { echo "$(ferry_root)/bin/versions/$1"; }
ferry_active_file()  { echo "$(ferry_root)/bin/.active-version"; }

# One hash of everything the darwin kubelet for a version is built from, other
# than upstream's tree: the overlays and the scripts that apply them.
#
# 'ferry build' used to rebuild the kubelet only when there was none, so a
# change to patches/ reached nobody who had built before it. v0.4.0 shipped
# that way -- stamped with a commit whose SafeMakeDir joins a relative subPath
# to the volume, carrying a kubelet that did not, so every emptyDir subPath
# failed with "escapes volume". build-kubelet.sh records this beside the binary
# and the build compares it. Empty when the sources are not here, as in an
# installed release, which has nothing to rebuild from.
ferry_kubelet_inputs() { # version
  local root; root="$(ferry_root)"
  [ -f "$root/build-kubelet.sh" ] && [ -d "$root/patches/kubelet" ] || return 0
  (
    cd "$root" || exit 1
    # SIGNATURES is what the build checks upstream against, not an input to
    # the binary; recording it should not rebuild every kubelet.
    find patches/kubelet "patches/kubelet-$(ferry_version_mm "$1")" -type f ! -name SIGNATURES -print0 2>/dev/null \
      | LC_ALL=C sort -z | xargs -0 shasum -a 256
    shasum -a 256 build-kubelet.sh lib/overlay.sh
  ) | shasum -a 256 | cut -d' ' -f1
}

# The same for the guest kernel: ferry's patches and configuration and the
# script that applies them, plus the upstream versions it names. A kernel that
# predates a patch is not wrong in a way anything reports -- it boots, and the
# pods it runs cost what the patch was written to save -- so this is the only
# way to tell. Empty without the sources, as in an installed release.
ferry_kernel_inputs() {
  local root; root="$(ferry_root)"
  [ -f "$root/kernel/build-kernel.sh" ] || return 0
  (
    cd "$root" || exit 1
    find kernel/patches -type f -name '*.patch' -print0 2>/dev/null \
      | LC_ALL=C sort -z | xargs -0 shasum -a 256
    shasum -a 256 kernel/build-kernel.sh kernel/slim.config kernel/usb-storage.config
  ) | shasum -a 256 | cut -d' ' -f1
}

# Which version bin/ currently points at. Empty if nothing has been built.
ferry_active_version() {
  local f; f="$(ferry_active_file)"
  [ -f "$f" ] && cat "$f"
}

# Put a built or downloaded binary into the store.
#
# The remove is not tidiness. Copying over a file that a process still has
# mapped rewrites the inode underneath it, and macOS then refuses to launch that
# path again -- forever, not just while the old process lives. Removing first
# leaves the running process holding the old inode and gives the new file a
# fresh one.
ferry_install_binary() { # version name source
  local dir; dir="$(ferry_version_dir "$1")"
  mkdir -p "$dir"
  rm -f "$dir/$2"
  cp "$3" "$dir/$2"
  chmod +x "$dir/$2"
}

# Point bin/<name> at this version, for every binary the version actually has.
#
# Relative, so the link keeps working if the checkout moves. Missing binaries
# are skipped rather than linked to nothing: ferry-proxyd is absent until the
# Kubernetes source has been cloned, and a dangling link reads as "built and
# broken" when the truth is "not built yet".
ferry_activate_version() { # version [binary...]
  local version="$1"; shift
  local dir; dir="$(ferry_version_dir "$version")"
  local bin; bin="$(ferry_bin_dir)"
  local names="${*:-$FERRY_VERSIONED_BINARIES}"
  [ -d "$dir" ] || return 1
  mkdir -p "$bin"
  local name
  for name in $names; do
    if [ -f "$dir/$name" ]; then
      rm -f "$bin/$name"
      ln -s "versions/$version/$name" "$bin/$name"
    elif [ -L "$bin/$name" ]; then
      # This version does not have it, but bin/ still points at some other
      # version's copy. Leaving that is how bin/ ends up serving two versions at
      # once -- a v1.35 kubelet beside a v1.34 ferry-proxyd -- so the stale link
      # goes rather than being left to look current.
      rm -f "$bin/$name"
    fi
  done
  echo "$version" > "$(ferry_active_file)"
}

# Does the store hold everything this version needs to run a cluster?
ferry_version_complete() { # version
  local dir name
  dir="$(ferry_version_dir "$1")"
  for name in kubelet kube-apiserver kube-controller-manager kube-scheduler etcd; do
    [ -f "$dir/$name" ] || return 1
  done
  return 0
}

# Versions in the store, oldest first.
ferry_version_list() {
  local dir; dir="$(ferry_versions_dir)"
  [ -d "$dir" ] || return 0
  # Version sort, so v1.9.0 comes before v1.34.0 rather than after it.
  find "$dir" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; 2>/dev/null | sort -V
}

ferry_write_manifest() { # version control-plane-version etcd-version
  local dir; dir="$(ferry_version_dir "$1")"
  mkdir -p "$dir"
  cat > "$dir/MANIFEST" <<MANIFEST
kubernetes=$1
control-plane=$2
etcd=$3
built=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MANIFEST
}

ferry_manifest_field() { # version field
  local dir; dir="$(ferry_version_dir "$1")"
  [ -f "$dir/MANIFEST" ] || return 1
  local value; value="$(sed -n "s/^$2=//p" "$dir/MANIFEST" | head -1)"
  [ -n "$value" ] || return 1
  echo "$value"
}

# Move a pre-store checkout's binaries into the store rather than making it
# rebuild. bin/kubelet was a regular file and bin/.kubelet-version recorded what
# it was built from; that is exactly a version directory with one binary in it.
#
# mv rather than cp: a rename keeps the inode, so a kubelet that is running
# right now stays runnable, and its signature is untouched.
ferry_adopt_legacy_binaries() {
  local bin; bin="$(ferry_bin_dir)"
  local legacy="$bin/.kubelet-version"
  [ -f "$legacy" ] || return 0
  if [ ! -f "$bin/kubelet" ] || [ -L "$bin/kubelet" ]; then rm -f "$legacy"; return 0; fi

  local version; version="$(cat "$legacy")"
  ferry_version_valid "$version" || { rm -f "$legacy"; return 0; }
  local dir; dir="$(ferry_version_dir "$version")"
  mkdir -p "$dir"
  local name
  for name in $FERRY_VERSIONED_BINARIES; do
    if [ -f "$bin/$name" ] && [ ! -L "$bin/$name" ]; then mv "$bin/$name" "$dir/$name"; fi
  done
  ferry_write_manifest "$version" "$(ferry_control_plane_version "$version")" \
    "$(ferry_etcd_version "$version")"
  ferry_activate_version "$version"
  rm -f "$legacy"
  echo "==> adopted the existing binaries as $version" >&2
}

# --- what a running cluster is --------------------------------------------

# The store is a property of a checkout; this is a property of a cluster. They
# are different facts and they can disagree -- a build moves the store and the
# cluster stays where it is until something restarts it -- so an upgrade needs
# both, and neither can be inferred from the other.
ferry_cluster_version_file() { echo "${FERRY_HOME:?FERRY_HOME must be set}/version"; }

ferry_write_cluster_version() { # k8s control-plane etcd
  local f; f="$(ferry_cluster_version_file)"
  mkdir -p "$(dirname "$f")"
  # Keep the version being replaced, so rollback has somewhere to go without
  # having to guess or ask.
  local previous=""
  previous="$(ferry_cluster_field kubernetes 2>/dev/null || true)"
  if [ -n "$previous" ] && [ "$previous" != "$1" ]; then
    cp "$f" "$(dirname "$f")/version.previous"
  fi
  cat > "$f" <<CLUSTER
kubernetes=$1
control-plane=$2
etcd=$3
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
CLUSTER
}

ferry_cluster_field() { # field
  local f; f="$(ferry_cluster_version_file)"
  [ -f "$f" ] || return 1
  local value; value="$(sed -n "s/^$1=//p" "$f" | head -1)"
  [ -n "$value" ] || return 1
  echo "$value"
}

ferry_previous_field() { # field
  local f; f="$(dirname "$(ferry_cluster_version_file)")/version.previous"
  [ -f "$f" ] || return 1
  local value; value="$(sed -n "s/^$1=//p" "$f" | head -1)"
  [ -n "$value" ] || return 1
  echo "$value"
}

# --- version skew ---------------------------------------------------------

# Kubernetes' rules, which are not ferry's to relax:
#
#   - a kubelet may be up to three minors older than the API server
#   - a kubelet may never be newer than the API server
#   - the control plane crosses one minor at a time
#
# The last one is why an upgrade from v1.32 to v1.34 is two upgrades. Skipping a
# minor skips that minor's storage migrations and API removals, and the failure
# is not at upgrade time, it is the next time something reads an object that was
# never converted.
ferry_skew_reason() { # from to -- prints why this is not allowed, or nothing
  local from="$1" to="$2"
  local fmaj tmaj fmin tmin fpat tpat
  fmaj="$(ferry_version_major "$from")"; tmaj="$(ferry_version_major "$to")"
  fmin="$(ferry_version_minor "$from")"; tmin="$(ferry_version_minor "$to")"
  fpat="$(ferry_version_patch "$from")"; tpat="$(ferry_version_patch "$to")"

  # A patch downgrade is a downgrade. v1.34.11 back to v1.34.0 stays inside the
  # minor, so no API is removed -- but the API server has still started once at
  # the newer patch, and a patch release is allowed to fix a storage bug by
  # writing something the older one does not expect. Rollback restores a
  # snapshot for exactly that reason; going backwards in place does not.
  if [ "$tmaj" -lt "$fmaj" ] \
     || { [ "$tmaj" -eq "$fmaj" ] && [ "$tmin" -lt "$fmin" ]; } \
     || { [ "$tmaj" -eq "$fmaj" ] && [ "$tmin" -eq "$fmin" ] && [ "$tpat" -lt "$fpat" ]; }; then
    echo "$to is older than $from, and Kubernetes does not support downgrading a control plane in place. To go back to a version this checkout has already run: ferry upgrade rollback"
    return
  fi
  if [ "$tmaj" -ne "$fmaj" ]; then
    echo "$from to $to crosses a major version, which ferry has never done and has no reason to believe works"
    return
  fi
  if [ "$(( tmin - fmin ))" -gt 1 ]; then
    echo "$from to $to skips $(( tmin - fmin - 1 )) minor version(s). Kubernetes upgrades one minor at a time; go to v$fmaj.$(( fmin + 1 )) first"
  fi
}

# Whether a kubelet at $1 may talk to an API server at $2.
ferry_kubelet_skew_reason() { # kubelet-version apiserver-version
  local kmaj kmin amaj amin
  kmaj="$(ferry_version_major "$1")"; amaj="$(ferry_version_major "$2")"
  kmin="$(ferry_version_minor "$1")"; amin="$(ferry_version_minor "$2")"
  if [ "$kmaj" -gt "$amaj" ] || { [ "$kmaj" -eq "$amaj" ] && [ "$kmin" -gt "$amin" ]; }; then
    echo "a kubelet at $1 is newer than the API server at $2, which Kubernetes does not support. Upgrade the control plane first: ferry upgrade apply $1"
    return
  fi
  if [ "$kmaj" -eq "$amaj" ] && [ "$(( amin - kmin ))" -gt 3 ]; then
    echo "a kubelet at $1 is more than three minor versions behind the API server at $2"
  fi
}
