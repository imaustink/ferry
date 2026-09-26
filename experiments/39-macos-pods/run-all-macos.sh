#!/usr/bin/env bash
# Everything, after a change to the runtime or the image: re-bake, boot a fresh
# mac-0 and run the pod, Service, exec and volume tests against it, each into
# its own log under build/, with a one-line verdict each.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
b="$here/build"
count() { grep -cE "$2" "$b/$1"; }
# How many of the patterns appear at all, however often each does.
checks() { f=$1; shift; n=0; for p in "$@"; do grep -qE "$p" "$b/$f" && n=$((n + 1)); done; echo $n; }

"$here/cycle-macos-machine.sh" > "$b/cycle.log" 2>&1
echo "machine + Services: $(grep -oE 'Ready [0-9]+ s after apply' "$b/cycle.log" | head -1); $(count cycle.log 'sees peer') of 9 replies"
if [ -n "${PROBES:-}" ]; then
    "$here/run-dns-probe.sh" > "$b/probe.log" 2>&1
    echo "probe: see build/probe.log"
fi
"$here/run-macos-exec.sh" > "$b/exec.log" 2>&1
echo "exec: $(count exec.log 'read: hello through stdin|sees peer|zsh 5|kubectl exited 1|step 3 on macOS') of 5 checks, $(count exec.log 'dyld\[') dyld errors"
"$here/run-macos-volumes.sh" > "$b/volumes.log" 2>&1
echo "volumes: $(count volumes.log 'hello from a ConfigMap|hunter2|tick [0-9]|HTTP 200|gitVersion|Read-only|updated|last thing') of 8 checks"
"$here/run-macos-attach.sh" > "$b/attach.log" 2>&1
echo "attach: $(checks attach.log 'tick [0-9]' 'log: hello through attach' 'shell on /dev/tty' 'run -i read: a line') of 4 checks"
"$here/run-macos-pvc.sh" > "$b/pvc.log" 2>&1
echo "PVC: $(count pvc.log 'written on macOS') of 3 reads (macOS pod, Linux pod VM, the Mac)"
# Last: it takes every macOS guest slot, so mac-0 goes first.
"$here/run-macos-vm.sh" > "$b/macvm.log" 2>&1
echo "macOS VM pods: $(count macvm.log '^    uid 0') of 3 as root, $(count macvm.log 'sysctl -w: allowed') of 2 sysctl -w, $(grep -oE 'third pod on a fresh VM: [a-z]+' "$b/macvm.log")"
