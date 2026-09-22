#!/usr/bin/env bash
# Every test that runs without a cluster.
#
# Some of them do more when there is one. image-identity-test.sh checks its
# invariants against the source either way, and additionally builds an image
# twice and runs it when a cluster is up -- so running this after `ferry up`
# tests strictly more than running it before.
#
#   ./tests/run.sh
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

failed=0
for test in "$here"/*-test.sh; do
  printf '\033[1m==> %s\033[0m\n' "$(basename "$test")"
  "$test" || failed=1
  echo
done

if [ "$failed" -eq 0 ]; then
  printf '\033[1m%s\033[0m\n' "all suites passed"
else
  printf '\033[1m%s\033[0m\n' "a suite failed"
  exit 1
fi
