#!/usr/bin/env bash
# Bakes a macOS machine image: golden-sipoff plus everything a node needs at
# boot, so ferry-node can boot a clone of it the way it boots the Linux node
# image.
#
#   /usr/local/libexec/ferry/   kubelet, ferry-darwin, podnet.dylib,
#                               ferry-macos-init.sh, kubelet.yaml.in
#   /Library/LaunchDaemons/dev.ferry.macos-node.plist
#   /private/var/ferry/darwin/os/   dyld and the shared cache, copied once here
#                                   rather than on every machine's first boot
#
#   ./bake-macos-node.sh [source golden] [out]
#   UPDATE=1 ./bake-macos-node.sh     reinstall the files into an existing out,
#                                     keeping its clone and its OS base
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
src="${1:-$here/.cache/golden-sipoff}"
out="${2:-$here/.cache/golden-node}"

(cd "$here/ferry-darwin" && go build -o "$here/build/ferry-darwin" .)
"$here/build-netpod.sh" >/dev/null

update="${UPDATE:-0}"
if [ "$update" != 1 ]; then
    rm -rf "$out"; mkdir -p "$out"
    cp -c "$src"/* "$out/"
fi
share="$here/build/bake-share"
rm -rf "$share"; mkdir -p "$share"
cp -c "$(readlink -f "$repo/bin/kubelet")" "$share/kubelet"
cp -c "$here/build/ferry-darwin" "$here/build/netpod/lib/podnet.dylib" \
    "$here/macos-node/ferry-macos-init.sh" "$here/macos-node/kubelet.yaml.in" \
    "$here/macos-node/dev.ferry.macos-node.plist" "$share/"

"$here/build/macvm" boot "$out" --share "$share" -- /bin/sh -c '
UPDATE='"$update"'
set -e
S=/private/var/ferry/share; F=/usr/local/libexec/ferry
mkdir -p "$S" "$F"; mount_virtiofs ferry "$S"
for f in kubelet ferry-darwin podnet.dylib ferry-macos-init.sh kubelet.yaml.in; do
    install -o root -g wheel -m 755 "$S/$f" "$F/$f"
done
install -o root -g wheel -m 644 "$S/dev.ferry.macos-node.plist" /Library/LaunchDaemons/dev.ferry.macos-node.plist
[ "$UPDATE" != 1 ] && rm -rf /private/var/ferry/darwin
"$F/ferry-darwin" -prepare -state /private/var/ferry/darwin -shim "$F/podnet.dylib"
# nfsd on at boot, so ferry-darwin's restart of it with the real exports is
# not also its first start (20 s on a fresh machine).
nfsd enable 2>/dev/null || true
umount "$S"
echo "baked: $(ls $F | tr "\n" " ")"
csrutil status
'
du -sh "$out"
