#!/bin/sh
# Runs inside a macOS guest, as root, through ferry-macagent. Asks what a
# shared-kernel macOS container needs to have its own / -- which is the
# difference between mode 2 on macOS and a Seatbelt profile.
#
# $1 is the image's binary, base64. The container root starts with only that
# binary and gains one piece of the OS at a time until it runs.
set -u
R=/private/var/ferry/ctr
echo "--- this guest: $(csrutil status | sed 's/.*: //') SIP, authenticated root $(csrutil authenticated-root status | sed 's/.*: //')"
rm -rf "$R"; mkdir -p "$R/bin" "$R/usr/lib" "$R/dev" "$R/tmp"
echo "$1" | base64 -d > "$R/bin/hello"; chmod 755 "$R/bin/hello"

try() {
    printf '%s\n' "--- $1"
    /usr/sbin/chroot "$R" /bin/hello probe > /tmp/out 2>&1
    echo "    exit $?"; sed 's/^/    /' /tmp/out | head -5
}

try "only the image's binary"

cp /usr/lib/dyld "$R/usr/lib/dyld"
try "+ a copy of /usr/lib/dyld"

cache=/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld
echo "--- the shared cache: $(du -sh "$cache" | cut -f1) in $(ls "$cache" | wc -l | tr -d ' ') files"
t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
mkdir -p "$R$cache" && cp "$cache"/* "$R$cache/"
t1=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
perl -e "printf \"    copied in %.1f s\n\", $t1-$t0"
try "+ the shared cache at its cryptex path"

mount_devfs devfs "$R/dev" && try "+ devfs"

mkdir -p "$R/System/Library/dyld" && ln "$R$cache"/* "$R/System/Library/dyld/"
try "+ the cache at /System/Library/dyld too"

echo "--- + DYLD_SHARED_CACHE_DIR and dyld's own account of it"
DYLD_SHARED_CACHE_DIR=/System/Library/dyld DYLD_PRINT_SEARCHING=1 DYLD_PRINT_SEGMENTS=1 \
    /usr/sbin/chroot "$R" /bin/hello probe 2>&1 | head -12 | sed 's/^/    /'
ls -l "$R$cache" | head -4 | sed 's/^/    /'

echo "--- the same binary outside the chroot, for comparison"
/private/var/ferry/ctr/bin/hello probe | sed 's/^/    /'

echo "--- a second container sharing the first one's OS files by hard link"
R2=/private/var/ferry/ctr2
rm -rf "$R2"; mkdir -p "$R2/bin" "$R2/usr/lib" "$R2/System/Library/dyld" "$R2/dev"
ln "$R/usr/lib/dyld" "$R2/usr/lib/dyld" && for f in "$R$cache"/*; do ln "$f" "$R2/System/Library/dyld/"; done
cp "$R/bin/hello" "$R2/bin/hello"
/usr/sbin/chroot "$R2" /bin/hello | sed 's/^/    /'
echo "    extra disk for container 2: $(du -sh "$R2" | cut -f1) as du counts it, all of it hard links"

t0=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
for i in 1 2 3 4 5 6 7 8 9 10; do /usr/sbin/chroot "$R" /bin/hello >/dev/null; done
t1=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
perl -e "printf \"--- start, chroot + exec, mean of 10: %.1f ms\n\", ($t1-$t0)*100"
umount "$R/dev" 2>/dev/null
