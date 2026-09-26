#!/bin/sh
# Runs inside a macOS guest, as root: builds the smallest chroot dyld accepts
# (dyld + the shared cache), fails to start a binary in it, and prints what the
# kernel logged about refusing to map the cache.
set -u
R=/private/var/ferry/why
cache=/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld
rm -rf "$R"; mkdir -p "$R/bin" "$R/usr/lib" "$R/System/Library/dyld"
echo "$1" | base64 -d > "$R/bin/hello"; chmod 755 "$R/bin/hello"
cp /usr/lib/dyld "$R/usr/lib/dyld"
cp "$cache"/* "$R/System/Library/dyld/"
echo "--- where the real cache lives, and where the copy does"
df "$cache" "$R/System/Library/dyld" | sed 's/^/    /'
start=$(date '+%Y-%m-%d %H:%M:%S')
/usr/sbin/chroot "$R" /bin/hello 2>&1 | head -1 | sed 's/^/    /'
sleep 1
echo "--- kernel, since the attempt"
log show --info --debug --start "$start" --predicate 'sender == "kernel" OR process == "kernel"' --style compact 2>/dev/null \
    | grep -iE 'shared.?region|csr|map_and_slide|vm_shared' | head -30 | sed 's/^/    /'
