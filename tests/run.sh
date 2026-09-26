#!/usr/bin/env bash
# Every test that runs without a cluster.
#
# Some of them do more when there is one. image-identity-test.sh checks its
# invariants against the source either way, and additionally builds an image
# twice and runs it when a cluster is up -- so running this after `ferry up`
# tests strictly more than running it before.
#
# Three kinds, in order: the shell suites here, `go test` in every Go module,
# and `swift test` in the Swift packages that have tests. The Swift ones build
# the package in debug, which takes minutes the first time and seconds after;
# FERRY_TEST_SWIFT=0 leaves them out. None of these starts a cluster: the ones
# that do are under tests/e2e and are run on their own.
#
#   ./tests/run.sh
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

failed=0
suite() { printf '\033[1m==> %s\033[0m\n' "$1"; }

for test in "$here"/*-test.sh; do
  suite "$(basename "$test")"
  "$test" || failed=1
  echo
done

# Every Go module outside experiments/, which are measurements rather than
# parts of ferry. A module with no packages (a vendored stub) has nothing to
# test and is not a failure.
suite "go test"
if ! command -v go >/dev/null 2>&1; then
  echo "  (skipped: go is not installed)"
else
  for mod in $(cd "$repo" && git ls-files '*go.mod' | grep -v '^experiments/' | xargs -n1 dirname | sort); do
    if [ -z "$(cd "$repo/$mod" && go list ./... 2>/dev/null)" ]; then continue; fi
    if out="$(cd "$repo/$mod" && go vet ./... 2>&1 && go test ./... 2>&1)"; then
      printf '  \033[32m✓\033[0m %s\n' "$mod"
    else
      printf '  \033[31m✗\033[0m %s\n' "$mod"; echo "$out" | tail -20 | sed 's/^/      /'
      failed=1
    fi
  done
fi
echo

suite "swift test"
if [ "${FERRY_TEST_SWIFT:-1}" = 0 ]; then
  echo "  (skipped: FERRY_TEST_SWIFT=0)"
elif ! command -v swift >/dev/null 2>&1; then
  echo "  (skipped: swift is not installed)"
else
  for pkg in ferry-cri experiments/18-node-image; do
    if out="$("$here/swift.sh" "$repo/$pkg" 2>&1)"; then
      printf '  \033[32m✓\033[0m %s: %s\n' "$pkg" "$(echo "$out" | grep -E '^. Test run with' | tail -1 | sed 's/^. //')"
    else
      printf '  \033[31m✗\033[0m %s\n' "$pkg"
      echo "$out" | grep -E '✘|error:' | grep -v 'Stale file' | head -20 | sed 's/^/      /'
      failed=1
    fi
  done
fi
echo

if [ "$failed" -eq 0 ]; then
  printf '\033[1m%s\033[0m\n' "all suites passed"
else
  printf '\033[1m%s\033[0m\n' "a suite failed"
  exit 1
fi
