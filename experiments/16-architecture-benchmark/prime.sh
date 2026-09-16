#!/usr/bin/env bash
# Pulls each benchmark image once, ever, and leaves it on the host as an archive
# the node-VM cells import instead of hitting a registry.
#
# The trick is that the staged directory is shared into the guest read-write, so
# a `ctr images export` inside the VM writes straight back out to the Mac. One
# pull, then every later run is local — which is both faster and the only way a
# battery of a dozen cells does not get rate-limited halfway through.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
harness="$here/../13-shared-kernel-cost"

OUTER="${OUTER:-public.ecr.aws/docker/library/debian:12}"
IMAGES="${IMAGES:-ghcr.io/linuxcontainers/alpine:3.20 public.ecr.aws/docker/library/python:3.12}"

"$harness/runtime.sh" stop >/dev/null 2>&1
sleep 2
POD_MEMORY_MIB=6144 "$harness/runtime.sh" start >/dev/null 2>&1

script="$here/.scratch/prime.sh"
mkdir -p "$here/.scratch"
{
  echo "BENCH_IMAGES=\"$IMAGES\""
  cat <<'INNER'
STAGE=/opt/bench
tar xzf "$STAGE/containerd.tar.gz" -C /usr/local
cp "$STAGE/runc" /usr/local/bin/runc
chmod +x /usr/local/bin/runc
export PATH=/usr/local/bin:$PATH
mkdir -p /etc/ssl/certs
cp "$STAGE/ca-certificates.crt" /etc/ssl/certs/ca-certificates.crt
mkdir -p /sys/fs/cgroup/init
for p in $(cat /sys/fs/cgroup/cgroup.procs 2>/dev/null); do
  echo "$p" >/sys/fs/cgroup/init/cgroup.procs 2>/dev/null
done
echo "+cpu +cpuset +io +memory +pids" >/sys/fs/cgroup/cgroup.subtree_control 2>/dev/null
containerd >/tmp/containerd.log 2>&1 &
until ctr version >/dev/null 2>&1; do sleep 0.1; done

for image in $BENCH_IMAGES; do
  archive="$STAGE/$(echo "$image" | tr '/:' '__').tar"
  if [ -f "$archive" ]; then echo "HAVE=$image"; continue; fi
  ctr images pull "$image" >/tmp/pull.log 2>&1 || { echo "PULL_FAIL=$image"; tail -2 /tmp/pull.log; continue; }
  # Export to the guest's own disk first. Writing the archive straight onto the
  # shared directory produces a tar containing only blobs — no index.json, no
  # oci-layout — which containerd then rejects as an unrecognized image format.
  # Whatever the cause, exporting locally and copying afterwards sidesteps it,
  # and the copy is verified before it counts as staged.
  local_archive="/tmp/$(basename "$archive")"
  ctr images export "$local_archive" "$image" >/tmp/export.log 2>&1 \
    || { echo "EXPORT_FAIL=$image"; tail -2 /tmp/export.log; continue; }
  if ! tar tf "$local_archive" | grep -q index.json; then
    echo "EXPORT_NO_INDEX=$image"
    echo "ENTRIES=$(tar tf "$local_archive" | head -3 | tr '\n' ' ')"
    continue
  fi
  cp "$local_archive" "$archive"
  sync
  echo "EXPORTED=$image"
  echo "STAGED_$(basename "$archive")=$(tar tf "$archive" | grep -c index.json)"
done
sync
sleep 10
echo PRIME_DONE=1
sleep 60
INNER
} >"$script"

"$harness/build/shkcost" \
  -count 1 -shape vm-per-pod -workload custom -privileged \
  -image "$OUTER" -cmd-file "$script" \
  -mount "$here/stage:/opt/bench" \
  -log-grep "=" -hold 300s -sample 60s -state shk-cri-state

ls -lh "$here/stage"
