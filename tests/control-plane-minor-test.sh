#!/usr/bin/env bash
# Walks a control plane across every minor ferry pins -- v1.34, v1.35, v1.36,
# v1.37 -- the way 'ferry upgrade apply' does, then rolls the last step back.
#
# A control plane only: its own etcd, API server, controller manager and
# scheduler, in a directory of its own and on ports of its own, with no runtime
# and no kubelet, so it runs beside a cluster without going near it. Each step
# is control-plane/up.sh with the environment apply passes -- etcd kept, the
# API server handed over through ferry-handover -- under the probe from
# experiments/28-control-plane-upgrades, and each step asserts:
#
#   - the API server reports the new minor;
#   - not one request failed, fresh connection or pooled, during the switch;
#   - a CRD and its object, a Deployment, a Secret, a PodDisruptionBudget and a
#     Lease written at v1.34 are the same objects, with the same data;
#   - the API server logged nothing about failing to decode what it read;
#   - the kubernetes Service still has its endpoint.
#
# Then v1.37 goes back to v1.36 the way rollback does across a minor: the
# snapshot from before the step is restored, with the revision bumped, and
# what was written since is gone.
#
# Skipped until the store has a control plane for every minor:
#   K8S_VERSION=v1.35.8 ./control-plane/fetch-binaries.sh   (and v1.36.4, v1.37.0)
#
#   ./tests/control-plane-minor-test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
FERRY_ROOT="$repo"
export FERRY_ROOT
# shellcheck source=../lib/versions.sh
. "$repo/lib/versions.sh"
# shellcheck source=../lib/upgrade.sh
. "$repo/lib/upgrade.sh"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }

# The newest version in the store with a whole control plane for each minor.
has_control_plane() { # version
  local d name; d="$(ferry_version_dir "$1")"
  for name in kube-apiserver kube-controller-manager kube-scheduler etcd etcdctl etcdutl; do
    [ -x "$d/$name" ] || return 1
  done
}
steps=()
for mm in v1.34 v1.35 v1.36 v1.37; do
  pick=""
  for v in $(ferry_version_list); do
    [ "$(ferry_version_mm "$v")" = "$mm" ] && has_control_plane "$v" && pick="$v"
  done
  if [ -z "$pick" ]; then
    echo "no $mm control plane in the store -- skipping"
    echo "  K8S_VERSION=<a $mm version> ./control-plane/fetch-binaries.sh"
    exit 0
  fi
  steps+=("$pick")
done
command -v go >/dev/null || { echo "go is needed to build the probe -- skipping"; exit 0; }

# Ports of its own, and not on any profile's grid, which shifts by thousands.
api=23543; etcd_client=23979; etcd_peer=23980; cm=23857; sched=23859
for p in $api $etcd_client $etcd_peer $cm $sched; do
  if nc -z 127.0.0.1 "$p" >/dev/null 2>&1; then echo "port $p is in use -- skipping"; exit 0; fi
done

work="$(mktemp -d)"
cleanup() {
  local pid
  for pid in "$work"/probe.pid "$work"/*.pid; do
    [ -f "$pid" ] && kill -KILL "$(cat "$pid")" 2>/dev/null
  done
  rm -rf "$work"
}
trap cleanup EXIT

printf '\033[1m%s\033[0m\n' "walking ${steps[*]}"
( cd "$repo/experiments/28-control-plane-upgrades/probe" && go build -o "$work/probe" . ) \
  || { bad "the probe did not build"; exit 1; }
handover="$repo/bin/ferry-handover"
[ -x "$handover" ] || ( cd "$repo/ferry-handover" && go build -o "$work/ferry-handover" . ) \
  && [ -x "$handover" ] || handover="$work/ferry-handover"

lan="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo 192.0.2.1)"
up() { # version [keep-etcd-and-hand-over]
  K8S_VERSION="$1" STATE="$work" POD_GATEWAY="$lan" ADVERTISE="$lan" NODE_NAME=minor-test \
    CLUSTER_CIDR=10.250.0.0/16 API_PORT=$api ETCD_CLIENT_PORT=$etcd_client ETCD_PEER_PORT=$etcd_peer \
    CONTROLLER_PORT=$cm SCHEDULER_PORT=$sched SERVICE_NODE_PORT_RANGE=30000-30099 \
    FERRY_KEEP_ETCD="${2:-}" FERRY_HANDOVER="${2:-}" FERRY_HANDOVER_BIN="$handover" \
    "$repo/control-plane/up.sh" >>"$work/up.log" 2>&1
}
kc() { kubectl --kubeconfig "$work/admin.conf" "$@"; }
minor_of_api() { kc get --raw /version 2>/dev/null | sed -n 's/.*"minor": *"\([0-9]*\).*/\1/p'; }
uids() {
  local o
  for o in crd/widgets.example.dev widget/w1 deployment/web secret/kept pdb/web lease/kept; do
    printf '%s=%s\n' "$o" "$(kc get "$o" -o jsonpath='{.metadata.uid}' 2>&1)"
  done
}

if up "${steps[0]}"; then ok "${steps[0]} started"
else bad "${steps[0]} did not start"; tail -20 "$work/up.log"; exit 1; fi

# Written at the oldest minor, and read back at every one after it.
kc apply -f - >/dev/null <<'YAML'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata: {name: widgets.example.dev}
spec:
  group: example.dev
  names: {kind: Widget, plural: widgets, singular: widget}
  scope: Namespaced
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec: {type: object, properties: {size: {type: integer}}}
---
apiVersion: v1
kind: Secret
metadata: {name: kept}
stringData: {token: written-at-the-oldest-minor}
---
apiVersion: coordination.k8s.io/v1
kind: Lease
metadata: {name: kept}
spec: {holderIdentity: minor-test, leaseDurationSeconds: 3600}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: web}
spec:
  replicas: 1
  selector: {matchLabels: {app: web}}
  template:
    metadata: {labels: {app: web}}
    spec: {containers: [{name: web, image: nginx:alpine}]}
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: {name: web}
spec:
  minAvailable: 1
  selector: {matchLabels: {app: web}}
YAML
kc wait --for=condition=Established crd/widgets.example.dev --timeout=30s >/dev/null 2>&1
printf 'apiVersion: example.dev/v1\nkind: Widget\nmetadata: {name: w1}\nspec: {size: 3}\n' | kc apply -f - >/dev/null
before="$(uids)"
case "$before" in *error*|*"=\n"*) bad "seeding at ${steps[0]}"; echo "$before" | sed 's/^/      /' ;;
  *) ok "seeded a CRD and its object, a Deployment, a Secret, a PDB and a Lease" ;; esac

snapshot=""
for i in 1 2 3; do
  from="${steps[$((i - 1))]}" to="${steps[$i]}"
  printf '\033[1m%s\033[0m\n' "$from -> $to"
  # What rollback would come back to.
  snapshot="$work/$from-to-$to.db"
  "$(ferry_version_dir "$from")/etcdctl" --endpoints="127.0.0.1:$etcd_client" snapshot save "$snapshot" >/dev/null 2>&1 \
    || bad "snapshot before $to"
  keep=""
  [ "$(ferry_store_etcd "$from")" = "$(ferry_store_etcd "$to")" ] && keep=1

  "$work/probe" -home "$work" -port $api > "$work/probe.out" 2>&1 &
  echo $! > "$work/probe.pid"
  sleep 1
  start=$(python3 -c 'import time;print(time.time())')
  up "$to" "$keep" || { bad "$to did not start"; tail -20 "$work/up.log"; break; }
  took="$(python3 -c "import time;print(round(time.time()-$start,1))")"
  sleep 2
  kill -INT "$(cat "$work/probe.pid")" 2>/dev/null; wait "$(cat "$work/probe.pid")" 2>/dev/null; rm -f "$work/probe.pid"

  got="$(minor_of_api)"
  [ "$got" = "$(ferry_version_minor "$to")" ] && ok "the API server is $to (up.sh took ${took}s)" \
    || bad "the API server reports minor '$got', not $to"
  readyz="$(awk '$1 == "readyz" {print $4 "/" $2}' "$work/probe.out")"
  get="$(awk '$1 == "get" {print $4 "/" $2}' "$work/probe.out")"
  # A request the bridge held while the new one got ready is slow, not failed.
  slowest="$(awk '$1 == "get" || $1 == "readyz" { for (i = 1; i < NF; i++) if ($i == "slowest") print $(i + 1) }' \
    "$work/probe.out" | sort -n | tail -1)"
  if [ -n "$keep" ] && [ "${readyz%%/*}" = 0 ] && [ "${get%%/*}" = 0 ]; then
    ok "handed over with no failed request (readyz $readyz, pooled get $get failed; slowest $slowest)"
  elif [ -z "$keep" ]; then
    ok "etcd changed, so a restart: readyz $readyz, pooled get $get failed"
  else
    bad "requests failed during the handover (readyz $readyz, pooled get $get)"
    sed 's/^/      /' "$work/probe.out"
  fi
  after="$(uids)"
  [ "$after" = "$before" ] && ok "every object is the one written at ${steps[0]}" \
    || { bad "objects changed"; diff <(echo "$before") <(echo "$after") | sed 's/^/      /'; }
  [ "$(kc get secret kept -o jsonpath='{.data.token}' | base64 -d)" = written-at-the-oldest-minor ] \
    && [ "$(kc get widget w1 -o jsonpath='{.spec.size}')" = 3 ] \
    && ok "and holds the same data" || bad "the data changed"
  decode="$(grep -ciE 'unable to decode|failed to decode|could not decode|unrecognized type' "$work/logs/kube-apiserver.log")"
  [ "$decode" = 0 ] && ok "no decode errors in the $to API server's log" \
    || bad "$decode decode errors in the $to API server's log"
  [ "$(kc get endpointslice kubernetes -o jsonpath='{.endpoints[0].addresses[0]}')" = "$lan" ] \
    && ok "the kubernetes Service still has its endpoint" || bad "the kubernetes Service lost its endpoint"
done

printf '\033[1m%s\033[0m\n' "the removed-API check reads what the API server publishes"
kc get endpoints >/dev/null 2>&1   # v1 Endpoints: deprecated since v1.33, with no removal set
metrics="$(kc get --raw /metrics 2>/dev/null)"
case "$metrics" in *'apiserver_requested_deprecated_apis{'*'resource="endpoints"'*) ok "the gauge is there once a deprecated API is asked for" ;;
  *) bad "no apiserver_requested_deprecated_apis gauge after asking for v1 Endpoints" ;; esac
[ -z "$(printf '%s\n' "$metrics" | ferry_removed_apis v1.38.0)" ] \
  && ok "and a deprecation with no removal release blocks nothing" \
  || bad "a deprecation with no removal release was reported as removed"

last="${steps[3]}" prev="${steps[2]}"
printf '\033[1m%s\033[0m\n' "rollback $last -> $prev, across a minor"
reason="$(ferry_rollback_restore_reason "$last" "$prev")"
[ -n "$reason" ] && ok "restores the snapshot: $reason" || bad "a rollback across a minor would keep the data"
kc create configmap written-at-"$(ferry_version_minor "$last")" >/dev/null 2>&1
STATE="$work" COMPONENTS="kube-scheduler kube-controller-manager kube-apiserver etcd" \
  "$repo/control-plane/down.sh" >/dev/null 2>&1
# Exactly the call ferry's etcd_restore makes.
rm -rf "$work/etcd.restoring"
if "$(ferry_version_dir "$prev")/etcdutl" snapshot restore "$snapshot" \
     --data-dir "$work/etcd.restoring" --name default \
     --initial-cluster "default=http://127.0.0.1:$etcd_peer" \
     --initial-advertise-peer-urls "http://127.0.0.1:$etcd_peer" \
     --bump-revision 1000000000 --mark-compacted >/dev/null 2>&1; then
  rm -rf "$work/etcd"; mv "$work/etcd.restoring" "$work/etcd"
  ok "restored the snapshot from before $last"
else bad "the restore failed"; fi
if up "$prev"; then ok "$prev started on it"; else bad "$prev did not start"; tail -20 "$work/up.log"; fi
[ "$(minor_of_api)" = "$(ferry_version_minor "$prev")" ] && ok "the API server is $prev again" \
  || bad "the API server is not $prev"
kc get configmap "written-at-$(ferry_version_minor "$last")" >/dev/null 2>&1 \
  && bad "what was written at $last survived the restore" \
  || ok "what was written at $last is gone, as rollback warns"
[ "$(uids)" = "$before" ] && ok "and everything from before it is the same objects" || bad "objects changed across the rollback"
revision="$("$(ferry_version_dir "$prev")/etcdctl" --endpoints="127.0.0.1:$etcd_client" endpoint status -w json 2>/dev/null \
  | tr ',' '\n' | sed -n 's/.*"revision":\([0-9]*\).*/\1/p' | head -1)"
[ "${revision:-0}" -gt 1000000000 ] && ok "at a bumped revision ($revision), so no watcher resumes into the past" \
  || bad "the revision was not bumped (${revision:-?})"

STATE="$work" "$repo/control-plane/down.sh" --purge >/dev/null 2>&1

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[1m%s\033[0m\n' "$pass passed"
else
  printf '\033[1m%s\033[0m\n' "$pass passed, $fail failed"
  exit 1
fi
