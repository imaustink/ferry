#!/usr/bin/env bash
# The rootless shape of a shared-kernel macOS container: a process confined by a
# Seatbelt profile to the OS (read-only) and its own root directory (read-write).
#
# There are no namespaces on Darwin, so this is the whole toolbox without root:
# no private filesystem view (paths inside the image are not at /), no private
# network stack, no private PID space. What Seatbelt does give is a kernel-
# enforced deny on everything the profile does not name.
#
#   ./seatbelt-run.sh <rootfs> <cmd...>
set -euo pipefail
root="$(cd "$1" && pwd -P)"; shift

profile="(version 1)
(deny default)
(allow process-fork process-exec signal)
(allow sysctl-read mach-lookup iokit-open ipc-posix-shm)
(allow file-read-metadata)
(allow file-read*
    (subpath \"/System\") (subpath \"/usr\") (subpath \"/bin\")
    (subpath \"/Library/Apple\") (subpath \"/private/etc\") (subpath \"/dev\")
    (subpath \"/private/var/db/timezone\") (literal \"/\")
    (subpath \"$root\"))
(allow file-write* (subpath \"$root\") (literal \"/dev/null\") (literal \"/dev/tty\"))
(allow network*)"

cd "$root"
exec env -i PATH="$root/bin:/usr/bin:/bin" HOME="$root" TMPDIR="$root/tmp" \
    /usr/bin/sandbox-exec -p "$profile" "$@"
