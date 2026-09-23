#!/usr/bin/env bash
# What an upgrade needs to know that is not the store itself: which version
# each node runs, which version this Mac's ferry-proxyd runs, what may be
# removed from the store, and what the API server says is about to break.
#
# Sourced by ferry after lib/versions.sh. Everything here is a decision rather
# than an act, so tests/upgrade-lib-test.sh can check it without a cluster.

# --- which version each node runs ------------------------------------------
#
# A checkout used to have one kubelet, bin/kubelet, and every node on the Mac
# ran it -- so every node moved together, and a control plane upgrade that
# flipped bin/ quietly queued an upgrade of every node for its next restart.
# Now each node runs the kubelet out of its own version's directory in the
# store, and the version is written down here when it starts, so that a restart
# -- 'ferry up', 'ferry node add' with a name used before, the login agent
# after a reboot -- brings it back as what it was.
#
# In FERRY_HOME rather than the node's run directory, which is under /tmp and
# does not survive the reboot this most needs to outlive. The run directory
# gets a copy, as a record of what the running process was started as.
ferry_node_version_file() { echo "${FERRY_HOME:?FERRY_HOME must be set}/node-versions/$1"; }

ferry_node_version() { # name -> version, or nothing
  local f; f="$(ferry_node_version_file "$1")"
  [ -f "$f" ] || return 1
  local v; v="$(head -1 "$f")"
  ferry_version_valid "$v" || return 1
  echo "$v"
}

ferry_record_node_version() { # name version
  local f; f="$(ferry_node_version_file "$1")"
  mkdir -p "$(dirname "$f")"
  echo "$2" > "$f"
}

ferry_forget_node_version() { rm -f "$(ferry_node_version_file "$1")"; }

# The version a node with no record starts at: the cluster's own, when this Mac
# runs the control plane and the store has a kubelet for it -- a kubelet at the
# API server's version is inside the skew by definition -- and otherwise what
# the checkout is built at, which is what bin/kubelet has always meant.
ferry_default_node_version() {
  local v
  if v="$(ferry_cluster_field kubernetes 2>/dev/null)" && [ -f "$(ferry_version_dir "$v")/kubelet" ]; then
    echo "$v"; return
  fi
  ferry_active_version
}

# What a node should run when it starts: its record if the store still has that
# kubelet, else the default. Prints the version and, on stderr, why when the
# record could not be honoured -- that is a node changing version without
# anyone asking, which must not happen silently.
ferry_node_start_version() { # name
  local v
  if v="$(ferry_node_version "$1")"; then
    if [ -f "$(ferry_version_dir "$v")/kubelet" ]; then echo "$v"; return; fi
    echo "node $1 last ran kubelet $v, which is no longer in the store" >&2
  fi
  ferry_default_node_version
}

# ferry-proxyd is kube-proxy, and there is one per Mac however many nodes it
# runs, so its version is the Mac's rather than a node's. It follows the Mac's
# own node -- index 0, the one 'ferry up' or 'ferry join' started -- which is
# always inside kube-proxy's skew: no newer than the API server, at most three
# minors behind it, and within three of every kubelet beside it, since those
# are held to the same window.
ferry_proxyd_version_file() { echo "${FERRY_HOME:?FERRY_HOME must be set}/proxyd-version"; }

ferry_proxyd_version() {
  local f; f="$(ferry_proxyd_version_file)"
  [ -f "$f" ] || return 1
  local v; v="$(head -1 "$f")"
  ferry_version_valid "$v" || return 1
  echo "$v"
}

ferry_record_proxyd_version() { mkdir -p "$(dirname "$(ferry_proxyd_version_file)")"; echo "$1" > "$(ferry_proxyd_version_file)"; }

# --- what a version pairs with, as built ------------------------------------

# The etcd a version in the store was actually fetched with, which is what
# decides whether etcd has to restart: MANIFEST first, the pairing table when a
# store predates the field.
ferry_store_etcd() { # version
  ferry_manifest_field "$1" etcd 2>/dev/null || ferry_etcd_version "$1"
}

# --- rollback ---------------------------------------------------------------

# Whether going back from $1 to $2 has to restore the pre-upgrade snapshot
# rather than keep the data directory, and why. Prints the reason, or nothing.
#
# Across an etcd minor it always did: the older etcd cannot read what the newer
# one migrated. Across a *Kubernetes* minor it now does too. An API server that
# has run at a newer minor may have written objects at storage versions the
# older one has never heard of -- an API that went GA and moved its storage
# version, a field the older one drops on its next write, a resource type the
# older one does not serve -- and upstream does not support downgrading a
# control plane in place for exactly that reason. The only state the older one
# is known to read is the one it left, which is the snapshot. What that costs is
# everything written since, and ferry says so, with the time, before doing it.
#
# Within a minor the data directory is kept: a patch release does not change
# storage versions, and a same-minor rollback losing an hour of writes to guard
# against something that does not happen is the wrong trade.
ferry_rollback_restore_reason() { # from to [etcd-from etcd-to]
  local ef="${3:-$(ferry_etcd_version "$1")}" et="${4:-$(ferry_etcd_version "$2")}"
  if [ "$(ferry_version_mm "$ef")" != "$(ferry_version_mm "$et")" ]; then
    echo "etcd $ef to $et crosses an etcd minor, and the older etcd cannot read a data directory the newer one migrated"
    return
  fi
  if [ "$(ferry_version_mm "$1")" != "$(ferry_version_mm "$2")" ]; then
    echo "$1 to $2 crosses a Kubernetes minor, and the $(ferry_version_mm "$2") API server is only known to read what it wrote itself"
  fi
}

# --- APIs that are about to go -----------------------------------------------

# From the API server's /metrics, the deprecated APIs something has asked for
# whose removal release is at or before the target. Prints one line per API:
#
#   <group>/<version> <resource> (removed in 1.NN)
#
# The gauge only covers requests this API server has served since it started,
# so an empty answer means nothing has asked lately, not that nothing will.
# What breaks is the client that asks, not the objects: the API server converts
# stored objects to whatever version is still served.
ferry_removed_apis() { # target-version < metrics
  local tmaj tmin
  tmaj="$(ferry_version_major "$1")"; tmin="$(ferry_version_minor "$1")"
  awk -v tmaj="$tmaj" -v tmin="$tmin" '
    /^apiserver_requested_deprecated_apis\{/ {
      value = $NF
      if (value + 0 == 0) next
      line = $0
      group = ""; version = ""; resource = ""; removed = ""
      if (match(line, /group="[^"]*"/))          group    = substr(line, RSTART + 7,  RLENGTH - 8)
      if (match(line, /[{,]version="[^"]*"/))    version  = substr(line, RSTART + 10, RLENGTH - 11)
      if (match(line, /resource="[^"]*"/))       resource = substr(line, RSTART + 10, RLENGTH - 11)
      if (match(line, /removed_release="[^"]*"/)) removed = substr(line, RSTART + 17, RLENGTH - 18)
      if (removed == "") next
      split(removed, rv, ".")
      if (rv[1] + 0 < tmaj + 0 || (rv[1] + 0 == tmaj + 0 && rv[2] + 0 <= tmin + 0)) {
        gv = (group == "" ? version : group "/" version)
        print gv " " resource " (removed in " removed ")"
      }
    }' | sort -u
}

# --- what the store may lose -----------------------------------------------

# Every version something still depends on: the cluster, where rollback would
# go, what bin/ points at, every node's kubelet and this Mac's ferry-proxyd.
# Removing any of them breaks a restart or a rollback.
ferry_store_referenced() {
  {
    ferry_cluster_field kubernetes 2>/dev/null
    ferry_previous_field kubernetes 2>/dev/null
    ferry_active_version
    local f
    for f in "${FERRY_HOME:?}"/node-versions/*; do [ -f "$f" ] && head -1 "$f"; done
    ferry_proxyd_version 2>/dev/null
  } | grep -E '^v[0-9]' | sort -u
}

# Versions in the store that nothing references. Printed oldest first.
ferry_store_unreferenced() {
  local refs; refs="$(ferry_store_referenced)"
  local v
  for v in $(ferry_version_list); do
    printf '%s\n' "$refs" | grep -qx "$v" || echo "$v"
  done
}
