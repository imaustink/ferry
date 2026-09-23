#!/usr/bin/env bash
# Runs a probe script in one privileged pod and keeps what it printed.
#   probe-at.sh LABEL [probe.sh]      (KERNEL, POD_MEMORY_MIB, ... as measure.sh)
here="$(cd "$(dirname "$0")" && pwd)"
HOLD="${HOLD:-30s}" "$here/measure.sh" "$1" 1 custom -cmd-file "$here/${2:-probe.sh}" \
  -privileged -log-grep "P|" | grep -E "footprint|running in"
