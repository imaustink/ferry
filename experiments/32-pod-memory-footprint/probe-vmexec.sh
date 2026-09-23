# How much of vmexec a cold start pulls into the page cache, and how long the
# start takes, at several read-ahead sizes. vmexec is not mapped by anything
# once the container is running, so drop_caches really does drop it.
# Needs -privileged.
sleep 3
{
apk add -q util-linux-misc coreutils >/dev/null 2>&1 || echo "apk failed"
mkdir -p /mnt/init /mnt/proc && mount -o ro -t ext4 /dev/vda /mnt/init && mount -t proc proc /mnt/proc
for ra in 8192 1024 256 128 64 32 16 8 4 0; do
  for i in 1 2 3 4 5; do
    echo $ra > /sys/block/vda/queue/read_ahead_kb; sync; echo 3 > /mnt/proc/sys/vm/drop_caches
    s=$(date +%s%N); /mnt/init/sbin/vmexec --help >/dev/null 2>&1; e=$(date +%s%N)
    echo "ra=$ra run=$i ms=$(( (e-s)/1000000 )) $(fincore -b -n /mnt/init/sbin/vmexec | awk '{print "resident_bytes=" $1}')"
  done
done
} 2>&1 | sed 's/^/P| /'
echo PROBE_DONE
sleep 100000
