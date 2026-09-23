#!/usr/bin/env bash
# Tests for lib/upgrade.sh: which version each node and ferry-proxyd start at,
# when a rollback restores the snapshot, which APIs the next minor removes, and
# what the store may lose. Against a throwaway store and FERRY_HOME.
#
#   ./tests/upgrade-lib-test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
FERRY_ROOT="$sandbox"
FERRY_HOME="$sandbox/home"
export FERRY_ROOT FERRY_HOME
mkdir -p "$FERRY_HOME" "$sandbox/bin"
# shellcheck source=../lib/versions.sh
. "$repo/lib/versions.sh"
# shellcheck source=../lib/upgrade.sh
. "$repo/lib/upgrade.sh"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
eq() { # description got want
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; echo "      got  '$2'"; echo "      want '$3'"; fi
}
store() { # version [binaries...]
  local v="$1"; shift
  mkdir -p "$sandbox/bin/versions/$v"
  local name
  for name in "${@:-kubelet ferry-proxyd kube-apiserver kube-controller-manager kube-scheduler etcd}"; do
    for n in $name; do printf '#!/bin/sh\n' > "$sandbox/bin/versions/$v/$n"; chmod +x "$sandbox/bin/versions/$v/$n"; done
  done
}
cluster_at() { printf 'kubernetes=%s\ncontrol-plane=%s\netcd=v3.6.5\n' "$1" "$1" > "$FERRY_HOME/version"; }

printf '\033[1m%s\033[0m\n' "which version a node starts at"
store v1.34.0
store v1.35.8
echo v1.34.0 > "$sandbox/bin/.active-version"
eq "with no cluster and no record, what the checkout is built at" \
   "$(ferry_node_start_version mac)" "v1.34.0"
cluster_at v1.35.8
eq "with a cluster, the cluster's own version" \
   "$(ferry_node_start_version mac)" "v1.35.8"
ferry_record_node_version mac v1.34.0
eq "with a record, the record -- a restart is not an upgrade" \
   "$(ferry_node_start_version mac)" "v1.34.0"
eq "and the record is per node" \
   "$(ferry_node_start_version other)" "v1.35.8"
rm -f "$sandbox/bin/versions/v1.34.0/kubelet"
out="$(ferry_node_start_version mac 2>&1 >/dev/null)"
eq "a record whose kubelet has gone falls back" \
   "$(ferry_node_start_version mac 2>/dev/null)" "v1.35.8"
case "$out" in *"no longer in the store"*) ok "and says so, rather than moving the node silently" ;;
  *) bad "and says so, rather than moving the node silently"; echo "      said '$out'" ;; esac
store v1.34.0
cluster_at v1.36.4
eq "a cluster version the store has no kubelet for is not a default" \
   "$(ferry_node_start_version newnode)" "v1.34.0"
echo "not-a-version" > "$(ferry_node_version_file junk)"
eq "a record that is not a version is ignored" \
   "$(ferry_node_version junk || echo none)" "none"
ferry_forget_node_version mac
eq "forgetting a node drops its record" "$(ferry_node_version mac || echo none)" "none"

printf '\033[1m%s\033[0m\n' "ferry-proxyd"
eq "has no version until one is recorded" "$(ferry_proxyd_version || echo none)" "none"
ferry_record_proxyd_version v1.35.8
eq "and then has that one" "$(ferry_proxyd_version)" "v1.35.8"

printf '\033[1m%s\033[0m\n' "when a rollback restores the snapshot"
eq "not within a minor" \
   "$(ferry_rollback_restore_reason v1.34.11 v1.34.0)" ""
case "$(ferry_rollback_restore_reason v1.35.8 v1.34.0)" in
  *"crosses a Kubernetes minor"*) ok "across a Kubernetes minor, even on the same etcd" ;;
  *) bad "across a Kubernetes minor, even on the same etcd" ;; esac
case "$(ferry_rollback_restore_reason v1.34.0 v1.33.0)" in
  *"crosses an etcd minor"*) ok "across an etcd minor, and that is the reason given" ;;
  *) bad "across an etcd minor, and that is the reason given" ;; esac
case "$(ferry_rollback_restore_reason v1.34.2 v1.34.1 v3.6.5 v3.5.21)" in
  *"etcd"*) ok "the store's etcd decides, when it is passed" ;;
  *) bad "the store's etcd decides, when it is passed" ;; esac

printf '\033[1m%s\033[0m\n' "APIs the next minor removes"
metrics='# HELP apiserver_requested_deprecated_apis [STABLE] Gauge of deprecated APIs that have been requested
# TYPE apiserver_requested_deprecated_apis gauge
apiserver_requested_deprecated_apis{group="flowcontrol.apiserver.k8s.io",removed_release="1.32",resource="flowschemas",subresource="",version="v1beta3"} 1
apiserver_requested_deprecated_apis{group="",removed_release="",resource="endpoints",subresource="",version="v1"} 1
apiserver_requested_deprecated_apis{group="example.dev",removed_release="1.36",resource="widgets",subresource="status",version="v1alpha1"} 1
apiserver_requested_deprecated_apis{group="example.dev",removed_release="1.37",resource="gadgets",subresource="",version="v1beta1"} 1
apiserver_requested_deprecated_apis{group="example.dev",removed_release="1.36",resource="idle",subresource="",version="v1beta1"} 0
apiserver_request_total{code="200"} 12'
got="$(printf '%s\n' "$metrics" | ferry_removed_apis v1.36.0)"
case "$got" in *"example.dev/v1alpha1 widgets (removed in 1.36)"*) ok "one removed in the target minor is reported" ;;
  *) bad "one removed in the target minor is reported"; echo "$got" ;; esac
case "$got" in *"flowcontrol.apiserver.k8s.io/v1beta3 flowschemas (removed in 1.32)"*) ok "and one removed before it" ;;
  *) bad "and one removed before it"; echo "$got" ;; esac
case "$got" in *gadgets*) bad "one removed in a later minor is not" ;; *) ok "one removed in a later minor is not" ;; esac
case "$got" in *endpoints*) bad "a deprecation with no removal is not" ;; *) ok "a deprecation with no removal is not" ;; esac
case "$got" in *idle*) bad "a gauge at zero is not" ;; *) ok "a gauge at zero is not" ;; esac
eq "nothing is reported when nothing asked" "$(printf 'apiserver_request_total 1\n' | ferry_removed_apis v1.36.0)" ""

printf '\033[1m%s\033[0m\n' "what the store may lose"
rm -rf "$sandbox/bin/versions" "$FERRY_HOME/node-versions" "$FERRY_HOME/proxyd-version"
for v in v1.33.0 v1.34.0 v1.35.8 v1.36.4 v1.37.0; do store "$v"; done
echo v1.37.0 > "$sandbox/bin/.active-version"
cluster_at v1.36.4
printf 'kubernetes=v1.35.8\n' > "$FERRY_HOME/version.previous"
ferry_record_node_version mac v1.34.0
eq "only what nothing references" "$(ferry_store_unreferenced | tr '\n' ' ')" "v1.33.0 "
ferry_record_proxyd_version v1.33.0
eq "ferry-proxyd's version counts as a reference" "$(ferry_store_unreferenced | tr '\n' ' ')" ""

printf '\033[1m%s\033[0m\n' "the etcd a stored version was fetched with"
printf 'kubernetes=v1.35.8\ncontrol-plane=v1.35.8\netcd=v3.6.9\n' > "$sandbox/bin/versions/v1.35.8/MANIFEST"
eq "is its MANIFEST's" "$(ferry_store_etcd v1.35.8)" "v3.6.9"
eq "or the pairing table's when it has none" "$(ferry_store_etcd v1.36.4)" "v3.6.5"

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[1m%s\033[0m\n' "$pass passed"
else
  printf '\033[1m%s\033[0m\n' "$pass passed, $fail failed"
  exit 1
fi
