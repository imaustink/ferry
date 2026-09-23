# Is a "cold" read really cold? Sectors read from each disk, and the cache,
# around one dropped-cache read. Needs -privileged.
sleep 3
{
mkdir -p /mnt/proc && mount -t proc proc /mnt/proc
dd if=/dev/urandom of=/blob bs=1M count=256 2>/dev/null; sync
grep -E "^(Cached|MemFree)" /mnt/proc/meminfo
echo 3 > /mnt/proc/sys/vm/drop_caches; echo "drop rc=$?"
grep -E "^(Cached|MemFree)" /mnt/proc/meminfo
for ra in 128 8192; do
  echo $ra > /sys/block/vdc/queue/read_ahead_kb; echo 3 > /mnt/proc/sys/vm/drop_caches
  before=$(awk '{print $3}' /sys/block/vdc/stat); reqs=$(awk '{print $1}' /sys/block/vdc/stat)
  echo "ra=$ra $(dd if=/blob of=/dev/null bs=1M 2>&1 | tail -1)"
  echo "  vdc read $(( ($(awk '{print $3}' /sys/block/vdc/stat) - before) / 2048 )) MiB in $(( $(awk '{print $1}' /sys/block/vdc/stat) - reqs )) requests"
  time cat /blob > /dev/null
done
cat /sys/block/vdc/queue/max_sectors_kb /sys/block/vdc/queue/max_hw_sectors_kb
} 2>&1 | sed 's/^/P| /'
echo PROBE_DONE
sleep 100000
