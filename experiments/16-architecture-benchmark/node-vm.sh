#!/usr/bin/env bash
# The node-VM architecture, as a script that runs inside one guest.
#
# This is what mode 2 actually is: one kernel, containerd, overlayfs, N
# containers. It is not ferry-cri with several containers in a pod — that shape
# gives every container its own ext4 and so duplicates the image cache N times,
# which is exactly the artifact this is here to avoid.
#
# Everything is reported as KEY=VALUE on stdout, because the host reads results
# out of the container log rather than by connecting to anything.
#
# Environment, passed through the pod's command line by the runner:
#   BENCH_COUNT     how many containers to start
#   BENCH_IMAGE     what to run
#   BENCH_WORKLOAD  idle | touch
set -u

STAGE=/opt/bench
COUNT="${BENCH_COUNT:-8}"
IMAGE="${BENCH_IMAGE:-docker.io/library/alpine:3.20}"
WORKLOAD="${BENCH_WORKLOAD:-idle}"

tar xzf "$STAGE/containerd.tar.gz" -C /usr/local || { echo SETUP_FAIL=containerd_untar; sleep 900; }
cp "$STAGE/runc" /usr/local/bin/runc
chmod +x /usr/local/bin/runc
export PATH=/usr/local/bin:$PATH

mkdir -p /etc/ssl/certs
cp "$STAGE/ca-certificates.crt" /etc/ssl/certs/ca-certificates.crt

grep -q cgroup2 /proc/mounts || mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null

# cgroup2 arrives mounted rw with every controller available and none of them
# delegated, so runc's first attempt to make a cgroup for a container fails.
#
# Handing the controllers down is not just a write: this is a namespaced root
# that holds our own processes, and cgroup v2 forbids a cgroup from having both
# member processes and enabled controllers. So the processes move into a leaf
# of their own first, and only then can the controllers be delegated. This is
# the same dance every nested container runtime does.
mkdir -p /sys/fs/cgroup/init
for p in $(cat /sys/fs/cgroup/cgroup.procs 2>/dev/null); do
  echo "$p" >/sys/fs/cgroup/init/cgroup.procs 2>/dev/null
done
echo "+cpu +cpuset +io +memory +pids" >/sys/fs/cgroup/cgroup.subtree_control 2>/dev/null \
  && echo SUBTREE_OK=1 || echo SUBTREE_FAIL=1

containerd >/tmp/containerd.log 2>&1 &
n=0
until ctr version >/dev/null 2>&1; do
  n=$((n + 1))
  [ "$n" -gt 300 ] && { echo SETUP_FAIL=containerd_never_ready; tail -5 /tmp/containerd.log; sleep 900; }
  sleep 0.1
done
echo CONTAINERD_READY_MS=$((n * 100))

# The image arrives once. Every container below is a snapshot of these layers,
# which is the whole point of the architecture: one copy on disk, one copy in
# the page cache.
#
# Prefer an archive staged on the host over the registry. A battery runs this
# cell a dozen times and every public registry tried — Docker Hub and ECR alike
# — starts answering 429 partway through, which reads as a benchmark failure and
# is not one. ./prime.sh writes the archive; this imports it.
ARCHIVE="$STAGE/$(echo "$IMAGE" | tr '/:' '__').tar"
pull_start=$(date +%s%N)
if [ -f "$ARCHIVE" ]; then
  ctr images import "$ARCHIVE" >/tmp/pull.log 2>&1 || { echo SETUP_FAIL=import; tail -3 /tmp/pull.log; sleep 900; }
  # An archive carries whatever reference it was saved under, which need not be
  # the one asked for. Run what was actually imported.
  imported=$(awk '/unpacking/ {print $2}' /tmp/pull.log | head -1)
  [ -n "$imported" ] && IMAGE="$imported"
  echo IMAGE_SOURCE=archive
  echo IMAGE_REF="$IMAGE"
else
  ctr images pull "$IMAGE" >/tmp/pull.log 2>&1 || { echo SETUP_FAIL=pull; tail -3 /tmp/pull.log; sleep 900; }
  echo IMAGE_SOURCE=registry
fi
pull_end=$(date +%s%N)
echo PULL_MS=$(((pull_end - pull_start) / 1000000))

case "$WORKLOAD" in
  idle)  CMD="sleep 100000" ;;
  touch) CMD="sh -c" ;;   # argument appended below, since it needs quoting
esac

start=$(date +%s%N)
i=0
while [ "$i" -lt "$COUNT" ]; do
  name="bench-$i"
  if [ "$WORKLOAD" = touch ]; then
    ctr run -d "$IMAGE" "$name" sh -c \
      'find / -xdev -type f -exec cat {} + >/dev/null 2>&1; echo TOUCHED; sleep 100000' \
      >>/tmp/run.log 2>&1 || { echo RUN_FAIL=$name; tail -2 /tmp/run.log | sed "s/^/RUN_ERR=$name /"; }
  else
    ctr run -d "$IMAGE" "$name" $CMD >>/tmp/run.log 2>&1 \
      || { echo RUN_FAIL=$name; tail -2 /tmp/run.log | sed "s/^/RUN_ERR=$name /"; }
  fi
  i=$((i + 1))
done
end=$(date +%s%N)

running=$(ctr containers ls -q 2>/dev/null | wc -l)
echo START_TOTAL_MS=$(((end - start) / 1000000))
echo START_PER_CONTAINER_MS=$(((end - start) / 1000000 / COUNT))
echo CONTAINERS_RUNNING=$running

# The guest's own view, to sit beside the host's. MemAvailable is what the guest
# believes it has left; the host's footprint is what the Mac actually paid.
sleep 20
awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^Cached:/{c=$2}
     END {printf "GUEST_MEM_TOTAL_MIB=%d\nGUEST_MEM_AVAILABLE_MIB=%d\nGUEST_CACHED_MIB=%d\n", t/1024, a/1024, c/1024}' /proc/meminfo

# What the snapshotter actually materialised, which is the disk half of layer
# sharing: N containers should cost one image plus N small upper layers.
du -sm /var/lib/containerd 2>/dev/null | awk '{print "CONTAINERD_DISK_MIB=" $1}'

echo BENCH_DONE=1
sleep 100000
