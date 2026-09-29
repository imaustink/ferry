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
printf '%s' "$update" > "$share/UPDATE"

# The steps that run inside the guest, as a file in the share rather than a
# single-quoted argument. Inline, an apostrophe in a comment (ferry-darwin's)
# once closed the quote early and leaked the rest to the host, where it ran as
# an unprivileged user against the host's own filesystem. A file has no such
# trap, and a quoted heredoc keeps the host from expanding any of it.
cat > "$share/bake-guest.sh" <<'GUEST'
#!/bin/sh
set -e
S=/private/var/ferry/share
F=/usr/local/libexec/ferry
UPDATE=$(cat "$S/UPDATE" 2>/dev/null || echo 0)
mkdir -p "$F"
for f in kubelet ferry-darwin podnet.dylib ferry-macos-init.sh kubelet.yaml.in; do
    install -o root -g wheel -m 755 "$S/$f" "$F/$f"
done
install -o root -g wheel -m 644 "$S/dev.ferry.macos-node.plist" /Library/LaunchDaemons/dev.ferry.macos-node.plist
# A fresh bake starts the OS base from nothing; an UPDATE keeps it. An if, not
# `[ ] && rm`, because under `set -e` a false test is a failed command.
if [ "$UPDATE" != 1 ]; then
    rm -rf /private/var/ferry/darwin
fi
"$F/ferry-darwin" -prepare -state /private/var/ferry/darwin -shim "$F/podnet.dylib"
# nfsd on at boot, so ferry-darwin's restart of it with the real exports is not
# also its first start (20 s on a fresh machine).
nfsd enable 2>/dev/null || true
# Record which macOS this image is, for the version a `FROM macos:<major>`
# image pins against. Written into the share, so the host can read it back.
sw_vers -productVersion > "$S/PRODUCT_VERSION" 2>/dev/null || true
echo "baked: $(ls "$F" | tr '\n' ' ')"
csrutil status
GUEST

# A tiny bootstrap -- no apostrophes, nothing the host expands -- mounts the
# share and runs the real script from it.
"$here/build/macvm" boot "$out" --share "$share" -- \
    /bin/sh -c 'set -e; S=/private/var/ferry/share; mkdir -p "$S"; mount_virtiofs ferry "$S"; sh "$S/bake-guest.sh"'
# Keep the recorded macOS version with the baked bundle, so whatever consumes it
# (ferry mac-image bake) can read the version without booting the guest again.
[ -f "$share/PRODUCT_VERSION" ] && cp "$share/PRODUCT_VERSION" "$out/PRODUCT_VERSION"
du -sh "$out"
