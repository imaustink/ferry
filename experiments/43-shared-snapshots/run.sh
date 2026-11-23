#!/usr/bin/env bash
# Runs experiment 43 against the running ferry of this checkout's profile.
# See FINDINGS.md. Needs a cluster that is up, and network access for
# BIG_IMAGE. Adds a node named "second" and removes it again on the way out;
# restarts ferry twice.
#
#   experiments/43-shared-snapshots/run.sh
#
# BIG_IMAGE should be one this Mac has never unpacked (the crash step is
# skipped if it already has a snapshot).
set -uo pipefail
cd "$(dirname "$0")/../.."

FERRY=./ferry
# The profile ferry picks for this checkout (ferry_profile in ./ferry).
SUFFIX=""
if [ -n "${FERRY_PROFILE:-}" ]; then SUFFIX="-$FERRY_PROFILE"
elif [ "$(git rev-parse --git-dir)" != "$(git rev-parse --git-common-dir)" ]; then
  SUFFIX="-$(basename "$PWD" | tr -c 'a-zA-Z0-9_-' '-' | sed 's/-*$//' | cut -c1-24)"
fi
[ "$SUFFIX" = "-default" ] && SUFFIX=""
R=${FERRY_RUN:-/tmp/ferry-run$SUFFIX}
export KUBECONFIG=${KUBECONFIG:-${FERRY_HOME:-$HOME/.ferry$SUFFIX}/admin.conf}
BIG_IMAGE=${BIG_IMAGE:-docker.io/library/python:3.9-bookworm}
SNAP=$R/snapshots
WORK=$(mktemp -d)
passed=0 failed=0

check() { # check DESCRIPTION CONDITION...
  local what=$1; shift
  if "$@"; then echo "  ✓ $what"; passed=$((passed+1)); else echo "  ✗ $what"; failed=$((failed+1)); fi
}
snapshots() { ls "$SNAP" 2>/dev/null | grep '\.ext4$' | sort; }
links() { stat -f %l "$SNAP/$1"; }
node0() { kubectl get nodes -l ferry.dev/node-index=0 -o jsonpath='{.items[0].metadata.name}'; }
run_on() { # run_on NODE NAME IMAGE CMD — waits for it to finish, prints its log
  local node=$1 name=$2 image=$3; shift 3
  kubectl delete pod "$name" --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl run "$name" --image="$image" --image-pull-policy=IfNotPresent --restart=Never \
    --overrides="{\"spec\":{\"nodeName\":\"$node\"}}" --command -- "$@" >/dev/null
  local p
  for _ in $(seq 300); do
    p=$(kubectl get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null)
    [ "$p" = Succeeded ] || [ "$p" = Failed ] && break
    sleep 1
  done
  kubectl logs "$name" 2>/dev/null
}
cleanup() {
  kubectl delete pod -l run --ignore-not-found --wait=false >/dev/null 2>&1
  if kubectl get node second >/dev/null 2>&1; then
    # Pods on the added node first: one left behind on a node that is gone
    # never finishes terminating.
    kubectl delete pod --field-selector spec.nodeName=second --force --grace-period=0 >/dev/null 2>&1
    $FERRY node rm second >/dev/null 2>&1
    kubectl delete node second --ignore-not-found >/dev/null 2>&1
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

N0=$(node0)
[ -n "$N0" ] || { echo "ferry is not up (KUBECONFIG=$KUBECONFIG)"; exit 1; }
echo "node 0 is $N0, snapshots in $SNAP"

echo "1. ferry-cri killed mid-unpack"
key_tmp=""
kubectl run big --image="$BIG_IMAGE" --restart=Never --overrides="{\"spec\":{\"nodeName\":\"$N0\"}}" \
  --command -- python -c "import json,sqlite3,ssl; print('python ok')" >/dev/null
for _ in $(seq 240); do
  key_tmp=$(ls -a "$SNAP" | grep '\.tmp$' | head -1)
  [ -n "$key_tmp" ] && break
  [ "$(kubectl get pod big -o jsonpath='{.status.phase}')" = Succeeded ] && break
  sleep 0.5
done
if [ -z "$key_tmp" ]; then
  echo "  - $BIG_IMAGE was already unpacked; skipped (set BIG_IMAGE)"
else
  # Killed as soon as the temp file shows: a small image can finish
  # unpacking in well under a second.
  pkill -9 -f "ferry-cri .*--state $R/cri( |$)"
  sleep 1
  check "the kill leaves a temp file, not a snapshot" [ -e "$SNAP/$key_tmp" ]
  # SnapshotManager names it .<key>.<uuid>.tmp
  key=$(echo "$key_tmp" | cut -d. -f2)
  check "and no snapshot ${key:0:12}… exists for it" [ ! -e "$SNAP/$key.ext4" ]
  $FERRY restart >/dev/null 2>&1
  out=$(run_on "$N0" big "$BIG_IMAGE" python -c "import json,sqlite3,ssl; print('python ok')")
  check "after a restart the image runs ($out)" [ "$out" = "python ok" ]
fi
kubectl delete pod big --ignore-not-found --wait=false >/dev/null

echo "2. two builds that differ only in ENV"
before=$(snapshots | wc -l)
for t in a b; do
  mkdir -p "$WORK/env$t"
  printf 'FROM docker.io/library/busybox:1.36\nENV FLAVOR=%s\n' $t > "$WORK/env$t/Dockerfile"
  $FERRY image build -t "envtest:$t" "$WORK/env$t" >/dev/null 2>&1
done
a=$(run_on "$N0" enva docker.io/library/envtest:a sh -c 'echo $FLAVOR')
b=$(run_on "$N0" envb docker.io/library/envtest:b sh -c 'echo $FLAVOR')
check "each runs with its own ENV ($a, $b)" [ "$a/$b" = "a/b" ]
added=$(( $(snapshots | wc -l) - before ))
check "they share one snapshot (added $added)" [ "$added" -le 1 ]

echo "3. a node added on this Mac uses node 0's snapshots"
for img in python:3.12 alpine:3.20; do run_on "$N0" "n0-${img//[:.]/}" "docker.io/library/$img" true >/dev/null; done
snapshots > "$WORK/pre"
$FERRY node add second >/dev/null 2>&1
check "the node joins" kubectl wait --for=condition=Ready node/second --timeout=180s >/dev/null 2>&1
t=$(date +%s)
p=$(run_on second n1-python docker.io/library/python:3.12 python -c 'print("ok")')
a=$(run_on second n1-alpine docker.io/library/alpine:3.20 echo ok)
echo "    both ran on second in $(( $(date +%s) - t ))s"
check "python and alpine run on second" [ "$p/$a" = "ok/ok" ]
snapshots > "$WORK/post"
check "no snapshot was unpacked for them" cmp -s "$WORK/pre" "$WORK/post"
shared=0
for f in $(ls "$R/node-1/cri/images" 2>/dev/null); do
  [ "$(stat -f %i "$R/node-1/cri/images/$f")" = "$(stat -f %i "$SNAP/$f" 2>/dev/null)" ] && shared=$((shared+1))
done
check "second's disks are links to the shared snapshots ($shared)" [ "$shared" -ge 2 ]
kubectl delete pod n1-python n1-alpine --force --grace-period=0 >/dev/null 2>&1
$FERRY node rm second >/dev/null 2>&1; kubectl delete node second --ignore-not-found >/dev/null 2>&1

echo "4. a rebuilt tag gives its old snapshot back"
mkdir -p "$WORK/rb"
for v in 1 2; do
  printf 'FROM docker.io/library/busybox:1.36\nRUN echo v%s-%s > /version\n' $v "$$" > "$WORK/rb/Dockerfile"
  $FERRY image build -t rebuild:dev "$WORK/rb" >/dev/null 2>&1
  out=$(run_on "$N0" rb docker.io/library/rebuild:dev cat /version)
  check "v$v runs ($out)" [ "$out" = "v$v-$$" ]
  snapshots > "$WORK/snap$v"
done
removed=$(comm -23 "$WORK/snap1" "$WORK/snap2" | wc -l | tr -d " ")
check "v1's snapshot is gone once v2 replaced it ($removed removed)" [ "$removed" -eq 1 ]

echo "5. disks left by a ferry-cri from before snapshots"
mkdir -p "$WORK/lg"; : > "$WORK/map"
for t in whole half; do
  snapshots > "$WORK/pre"
  printf 'FROM docker.io/library/busybox:1.36\nRUN echo %s-%s > /kind\n' $t "$$" > "$WORK/lg/Dockerfile"
  $FERRY image build -t "legacy:$t" "$WORK/lg" >/dev/null 2>&1
  run_on "$N0" "lg-$t" "docker.io/library/legacy:$t" cat /kind >/dev/null
  f=$(comm -13 "$WORK/pre" <(snapshots))
  id=$(kubectl get pod "lg-$t" -o jsonpath='{.status.containerStatuses[0].imageID}')
  echo "$t $f $id" >> "$WORK/map"
  kubectl delete pod "lg-$t" --wait=true >/dev/null
done
read -r _ W WID < <(grep '^whole' "$WORK/map"); read -r _ H HID < <(grep '^half' "$WORK/map")
$FERRY down >/dev/null 2>&1
# whole: the snapshot becomes an old-style disk, named by the image digest
inode=$(stat -f %i "$SNAP/$W"); rm -f "$R/cri/images/$W"; mv "$SNAP/$W" "$R/cri/image-sha256_${WID#sha256:}.ext4"
# half: no snapshot, and a disk that was never finished (no superblock)
rm -f "$R/cri/images/$H" "$SNAP/$H"
dd if=/dev/zero of="$R/cri/image-sha256_${HID#sha256:}.ext4" bs=1m count=50 2>/dev/null
$FERRY up >/dev/null 2>&1
check "the whole one is adopted in place (same inode)" [ "$(stat -f %i "$SNAP/$W" 2>/dev/null)" = "$inode" ]
# 'ferry up' starts ferry-cri's log afresh, so this is this start's.
check "the half one is thrown away" grep -q "was never finished" "$R/logs/ferry-cri.log"
check "no old-style disk is left" [ "$(ls "$R/cri" | grep -c '^image-')" -eq 0 ]
w=$(run_on "$N0" v-whole docker.io/library/legacy:whole cat /kind)
h=$(run_on "$N0" v-half docker.io/library/legacy:half cat /kind)
check "both images run ($w, $h)" [ "$w/$h" = "whole-$$/half-$$" ]

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
