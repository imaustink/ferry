#!/usr/bin/env bash
# Put a built tarball on GitHub Releases, where install.sh looks for it.
#
#   ./release/publish.sh --version v0.1.0
#
# Releases are built here rather than in CI, because building them needs a Mac
# on macOS 26 with Swift 6.4 and a Docker daemon for the guest kernel, and
# nothing hosted offers that combination today. The consequence worth naming:
# the tarball is whatever this Mac had built, so this script refuses to publish
# one whose VERSION does not match the tag, and refuses a dirty tree.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

version=""
out="$root/dist"
notes=""
draft=1
while [ $# -gt 0 ]; do
  case "$1" in
    --version) version="${2:-}"; shift 2 ;;
    --version=*) version="${1#*=}"; shift ;;
    --out) out="${2:-}"; shift 2 ;;
    --notes) notes="${2:-}"; shift 2 ;;
    # A draft by default. Publishing is the irreversible half -- install.sh
    # starts serving it to every machine the moment it is live.
    --publish) draft="" ; shift ;;
    *) die "usage: release/publish.sh --version vX.Y.Z [--notes <file>] [--publish]" ;;
  esac
done
[ -n "$version" ] || die "--version is required, such as v0.1.0"

command -v gh >/dev/null || die "the gh CLI is not installed: brew install gh"
gh auth status >/dev/null 2>&1 || die "gh is not logged in: gh auth login"

tarball="$out/ferry-$version-darwin-arm64.tar.gz"
[ -f "$tarball" ] || die "$tarball does not exist -- run: ./release/build.sh --version $version"
[ -f "$tarball.sha256" ] || die "$tarball.sha256 is missing; rebuild the tarball"

# The tag has to exist and has to be what was packaged. A release whose tarball
# was built from a different tree than its tag is the kind of thing nobody
# notices until they are debugging the wrong source.
git -C "$root" rev-parse "$version" >/dev/null 2>&1 \
  || die "there is no tag $version -- git tag -a $version -m '...' && git push origin $version"
[ -z "$(git -C "$root" status --porcelain)" ] \
  || die "the tree is dirty; commit or stash before publishing a release"

packaged="$(tar -xOzf "$tarball" "ferry-$version/VERSION" 2>/dev/null | sed -n 's/^commit=//p')"
tagged="$(git -C "$root" rev-parse "$version")"
[ "$packaged" = "$tagged" ] \
  || die "the tarball was built from $packaged but $version is $tagged -- rebuild it"
ok "tarball matches tag $version"

# Which repository, decided once and passed to every call.
#
# gh resolves the repo from the current directory, and this script can be run
# from anywhere -- `path/to/ferry/release/publish.sh` from a different checkout
# resolved that other repo for the `view` and then uploaded to it, because the
# upload and create calls named no repo at all. Asking from $root and then
# saying so every time removes the question.
repo="$(git -C "$root" remote get-url origin 2>/dev/null \
        | sed -e 's|^git@github.com:||' -e 's|^https://github.com/||' -e 's|\.git$||')"
[ -n "$repo" ] || die "could not work out which GitHub repository $root belongs to"
ok "publishing to $repo"

bold "publishing ferry $version"
if gh release view "$version" --repo "$repo" >/dev/null 2>&1; then
  ok "release exists; replacing its assets"
  gh release upload "$version" "$tarball" "$tarball.sha256" --repo "$repo" --clobber \
    || die "upload failed"
else
  args=(--repo "$repo" --title "ferry $version")
  if [ -n "$notes" ]; then args+=(--notes-file "$notes"); else args+=(--generate-notes); fi
  [ -n "$draft" ] && args+=(--draft)
  gh release create "$version" "$tarball" "$tarball.sha256" "${args[@]}" \
    || die "could not create the release"
fi

echo
if [ -n "$draft" ]; then
  bold "published as a draft"
  echo "  Review it, then: gh release edit $version --draft=false"
  echo "  install.sh will not see it until then."
else
  bold "published"
  echo "  curl -sfL https://get.ferry.kurpuis.com | sh -"
fi
