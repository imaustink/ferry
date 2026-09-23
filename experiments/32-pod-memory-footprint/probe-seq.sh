# What the smaller read-ahead costs a cold sequential read of a large file on
# the container's root filesystem. Needs -privileged.
sleep 3
{
mkdir -p /mnt/proc && mount -t proc proc /mnt/proc
dd if=/dev/urandom of=/blob bs=1M count=512 2>/dev/null; sync
for i in 1 2 3 4 5; do
  for ra in 8192 1024 512 256 128; do
    echo $ra > /sys/block/vdb/queue/read_ahead_kb; echo 3 > /mnt/proc/sys/vm/drop_caches
    echo "ra=$ra $(dd if=/blob of=/dev/null bs=1M 2>&1 | tail -1)"
  done
done
} 2>&1 | sed 's/^/P| /'
echo PROBE_DONE
sleep 100000
