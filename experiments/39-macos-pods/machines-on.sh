#!/usr/bin/env bash
# Turns machines on for this checkout's cluster, with ferry-machined told
# where the macOS machine image is. FERRY_MAC_IMAGE is read by ferry's
# start_machines and passed on as --mac-image.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
export FERRY_MAC_IMAGE="${FERRY_MAC_IMAGE:-$here/.cache/golden-node}"
exec "$here/../../ferry" machines "${1:-enable}"
