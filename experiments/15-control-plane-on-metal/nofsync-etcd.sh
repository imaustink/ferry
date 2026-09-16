#!/usr/bin/env bash
# etcd with durability turned off, so the same control plane can be started
# twice and the difference attributed to fsync rather than to anything else.
#
# --unsafe-no-fsync is etcd's own flag and means exactly what it says: a crash
# loses data. It is here to isolate a cost, not to be run.
exec "$HOME/ferry/bin/etcd" --unsafe-no-fsync "$@"
