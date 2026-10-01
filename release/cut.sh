#!/usr/bin/env bash
# Cut a ferry release: build, package, tag and publish in one command.
#
# A release is not one binary. It is the subset of a *built* checkout a cluster
# reads at runtime, stitched from binaries this Mac compiled, a guest kernel and
# node image that took a running cluster to make, and a git tag that has to name
# the exact commit the tarball was cut from. Miss one and the failure lands on
# someone else's Mac after a 500 MB download. This script does the whole dance
# and refuses the footguns that make it a pain to do by hand: a stale binary
# left over from before the merge, a tag that does not match the tarball, a
# dirty tree, a half-synced main.
#
# It runs only from the main checkout, never a linked git worktree. A release
# needs the kernel, node image, nft and CNI plugins that live beside this
# checkout; a worktree has none of them, and reconstructing them by copying from
# the main checkout is exactly the fragile thing this script exists to avoid. So
# cut releases from main, where everything already is.
#
#   ./release/cut.sh --version v0.15.0            # build, package, tag, draft
#   ./release/cut.sh --version v0.15.0 --publish  # ... and publish it live
#   ./release/cut.sh --bump minor --publish       # next minor from the last tag
#
# The order is deliberate: build, then package, then tag, then publish. Packaging
# before tagging means a build that fails leaves no dangling tag behind; tagging
# before publishing means publish.sh can hold its tag/tarball-commit check.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
# shellcheck source=../lib/versions.sh
. "$root/lib/versions.sh"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

version=""; bump="minor"; k8s=""; publish=""; notes=""; yes=""; skip_build=""; without_node_image=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version) version="${2:-}"; shift 2 ;;
    --version=*) version="${1#*=}"; shift ;;
    --bump) bump="${2:-}"; shift 2 ;;
    --bump=*) bump="${1#*=}"; shift ;;
    --kubernetes-version) k8s="${2:-}"; shift 2 ;;
    --kubernetes-version=*) k8s="${1#*=}"; shift ;;
    --notes) notes="${2:-}"; shift 2 ;;
    --notes=*) notes="${1#*=}"; shift ;;
    --publish) publish=1; shift ;;
    --skip-build) skip_build=1; shift ;;
    --without-node-image) without_node_image=1; shift ;;
    --yes|-y) yes=1; shift ;;
    *) die "usage: release/cut.sh [--version vX.Y.Z | --bump major|minor|patch] [--kubernetes-version vX.Y.Z] [--without-node-image] [--skip-build] [--notes <file>] [--publish] [--yes]" ;;
  esac
done

command -v gh >/dev/null || die "the gh CLI is not installed: brew install gh"
gh auth status >/dev/null 2>&1 || die "gh is not logged in: gh auth login"

# --- this must be the main checkout, on main, clean and current -----------
# A linked worktree's .git points back at the main checkout's object store but
# has none of the release artifacts beside it; building there means copying them
# around, which is what went wrong before this script existed.
if [ "$(git -C "$root" rev-parse --git-dir)" != "$(git -C "$root" rev-parse --git-common-dir)" ]; then
  die "this is a linked git worktree, which has none of the release artifacts -- cut releases from the main checkout"
fi
branch="$(git -C "$root" symbolic-ref --quiet --short HEAD || true)"
[ -n "$branch" ] || die "HEAD is detached -- releases are cut from main: git checkout main"
[ "$branch" = "main" ] || die "on '$branch', not main -- releases are cut from main: git checkout main"
[ -z "$(git -C "$root" status --porcelain)" ] || die "the tree is dirty; commit or stash before cutting a release"

bold "syncing main with origin"
git -C "$root" fetch origin main --tags >/dev/null 2>&1 || die "could not fetch origin"
git -C "$root" merge --ff-only origin/main >/dev/null 2>&1 \
  || die "local main is not a fast-forward of origin/main -- reconcile them first"
ok "main at $(git -C "$root" rev-parse --short HEAD)"

# --- the version ----------------------------------------------------------
# An explicit --version wins; otherwise bump the newest vX.Y.Z tag. The default
# bump is minor, which is what every ferry release so far has been.
if [ -z "$version" ]; then
  latest="$(git -C "$root" tag --list 'v[0-9]*' --sort=-v:refname | head -1)"
  [ -n "$latest" ] || die "no existing vX.Y.Z tag to bump from -- pass --version"
  v="${latest#v}"; maj="${v%%.*}"; rest="${v#*.}"; min="${rest%%.*}"; pat="${rest#*.}"
  case "$bump" in
    major) maj=$((maj + 1)); min=0; pat=0 ;;
    minor) min=$((min + 1)); pat=0 ;;
    patch) pat=$((pat + 1)) ;;
    *) die "--bump is major, minor or patch" ;;
  esac
  version="v$maj.$min.$pat"
fi
case "$version" in
  v[0-9]*.[0-9]*.[0-9]*) : ;;
  *) die "--version must look like v1.2.3" ;;
esac
git -C "$root" rev-parse -q --verify "refs/tags/$version" >/dev/null 2>&1 \
  && die "tag $version already exists -- bump to a new version or delete the tag first"

[ -n "$k8s" ] || k8s="$FERRY_DEFAULT_K8S_VERSION"

# --- confirm --------------------------------------------------------------
echo
bold "cut ferry $version"
echo "  kubernetes   $k8s"
echo "  commit       $(git -C "$root" rev-parse --short HEAD) (main)"
echo "  binaries     $([ -n "$skip_build" ] && echo 'as-is (--skip-build)' || echo 'rebuilt (ferry build)')"
echo "  node image   $([ -n "$without_node_image" ] && echo 'excluded (--without-node-image)' || echo 'included')"
echo "  publish      $([ -n "$publish" ] && echo 'LIVE -- served to every machine immediately' || echo 'draft (review, then: gh release edit '"$version"' --draft=false)')"
echo
# A draft is reversible; a live publish is not. Confirm before the irreversible
# half unless told to go ahead (--yes), and refuse to guess when there is no
# terminal to ask at.
if [ -z "$yes" ]; then
  if [ -t 0 ]; then
    printf '  proceed? [y/N] '; read -r reply
    case "$reply" in y | Y | yes | YES) : ;; *) die "aborted" ;; esac
  else
    die "not a terminal; pass --yes to proceed non-interactively"
  fi
fi

# --- build, package, tag, publish -----------------------------------------
if [ -z "$skip_build" ]; then
  echo; bold "building binaries (ferry build)"
  ( cd "$root" && ./ferry build --kubernetes-version "$k8s" ) || die "ferry build failed"
fi

echo; bold "packaging the tarball"
build_args=(--version "$version" --kubernetes-version "$k8s")
[ -n "$without_node_image" ] && build_args+=(--without-node-image)
"$here/build.sh" "${build_args[@]}" || die "release/build.sh failed"

echo; bold "tagging $version"
git -C "$root" tag -a "$version" -m "ferry $version" || die "could not create tag $version"
git -C "$root" push origin "$version" \
  || { git -C "$root" tag -d "$version" >/dev/null 2>&1; die "could not push tag $version (removed the local tag)"; }
ok "tagged and pushed $version"

echo; bold "publishing"
publish_args=(--version "$version")
[ -n "$notes" ] && publish_args+=(--notes "$notes")
[ -n "$publish" ] && publish_args+=(--publish)
"$here/publish.sh" "${publish_args[@]}" || die "release/publish.sh failed"
