#!/usr/bin/env bash
# One iteration on the macOS machine: delete it, stop mode 2 so ferry-node
# lets go of the machine network, rebuild ferry-node, reinstall the boot files
# into golden-node, start mode 2 again and boot a fresh machine.
#
#   ./cycle-macos-machine.sh          then run-macos-machine.sh
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
state=$("$repo/ferry" profile | awk '$1 == "state" {print $2}')
export KUBECONFIG="$state/admin.conf"

kubectl delete machine mac-0 --ignore-not-found --timeout=90s >/dev/null 2>&1
"$here/machines-on.sh" disable >/dev/null 2>&1
(cd "$repo/experiments/18-node-image" && OUT="$repo/bin/ferry-node" ./rebuild-tool.sh 2>&1 | tail -1)
UPDATE=1 "$here/bake-macos-node.sh" 2>&1 | grep -E "baked|SIP|error"
"$here/machines-on.sh" 2>&1 | grep -E "machine network|machines are|✗"
exec "$here/run-macos-machine.sh"
