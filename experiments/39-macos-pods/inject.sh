#!/usr/bin/env bash
# Puts ferry-macagent into a golden bundle's Data volume as a LaunchDaemon, so
# the guest runs it at boot -- before Setup Assistant, before any user exists.
#
# Needs root, once per golden image: launchd ignores a daemon plist that is not
# root:wheel, and a disk image attached by a user mounts with ownership off.
# Only the disk this script attaches is touched; it refuses any APFS volume
# whose physical store is not that disk.
#
#   sudo ./inject.sh .cache/golden
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
bundle="$(cd "$1" && pwd)"
[[ $EUID -eq 0 ]] || { echo "inject.sh: run with sudo" >&2; exit 1; }
[[ -x "$here/build/ferry-macagent" ]] || { echo "inject.sh: run build.sh first" >&2; exit 1; }

whole=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$bundle/Disk.img" \
    | awk 'NR==1 {print $1}')
echo "==> attached $bundle/Disk.img as $whole"
mnt=$(mktemp -d /tmp/ferry-golden.XXXX)
cleanup() {
    diskutil unmount "$mnt" >/dev/null 2>&1 || true
    hdiutil detach "$whole" >/dev/null 2>&1 || diskutil eject "$whole" >/dev/null 2>&1 || true
    rmdir "$mnt" 2>/dev/null || true
}
trap cleanup EXIT

# The Data-role volume in the APFS container whose physical store is on $whole.
data=$(diskutil apfs list -plist | python3 -c '
import plistlib, sys
whole = sys.argv[1].removeprefix("/dev/")
for c in plistlib.loads(sys.stdin.buffer.read())["Containers"]:
    if not any(s["DeviceIdentifier"].startswith(whole + "s") for s in c["PhysicalStores"]):
        continue
    for v in c["Volumes"]:
        if "Data" in v.get("Roles", []):
            print(v["DeviceIdentifier"])
' "$whole")
[[ -n "$data" ]] || { echo "inject.sh: no Data volume on $whole" >&2; exit 1; }

diskutil mount -mountPoint "$mnt" "$data" >/dev/null
diskutil enableOwnership "$mnt" >/dev/null
echo "==> mounted $data (guest Data volume) at $mnt"

install -d -o root -g wheel -m 755 "$mnt/usr/local/libexec" "$mnt/Library/LaunchDaemons"
install -o root -g wheel -m 755 "$here/build/ferry-macagent" "$mnt/usr/local/libexec/ferry-macagent"
install -o root -g wheel -m 644 "$here/dev.ferry.macagent.plist" "$mnt/Library/LaunchDaemons/dev.ferry.macagent.plist"
ls -l "$mnt/usr/local/libexec/ferry-macagent" "$mnt/Library/LaunchDaemons/dev.ferry.macagent.plist"
echo "==> injected"
