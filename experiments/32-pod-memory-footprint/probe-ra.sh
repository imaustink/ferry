# What vminitd actually needs resident, and what read-ahead costs a
# sequential read. Needs -privileged: /proc/sys is read-only in a container,
# so drop_caches is written through a proc of its own.
sleep 5
{
apk add -q util-linux-misc >/dev/null 2>&1 || echo "apk failed"
mkdir -p /mnt/init /mnt/proc && mount -o ro -t ext4 /dev/vda /mnt/init && mount -t proc proc /mnt/proc
echo "-- at start"; grep -E "^(Cached|MemFree)" /proc/meminfo; fincore -b /mnt/init/sbin/vminitd /mnt/init/sbin/vmexec
for d in vda vdb; do echo 128 > /sys/block/$d/queue/read_ahead_kb; done
sync; echo 3 > /mnt/proc/sys/vm/drop_caches; sleep 20
echo "-- 20s after drop_caches at ra=128k (vminitd refaults only what it uses)"; grep -E "^(Cached|MemFree)" /proc/meminfo; fincore -b /mnt/init/sbin/vminitd /mnt/init/sbin/vmexec
dd if=/dev/urandom of=/blob bs=1M count=256 2>/dev/null; sync
for ra in 8192 1024 512 128; do
  echo $ra > /sys/block/vdb/queue/read_ahead_kb; echo 3 > /mnt/proc/sys/vm/drop_caches
  echo "seq read ra=$ra: $(dd if=/blob of=/dev/null bs=1M 2>&1 | tail -1)"
done
for ra in 8192 128; do
  echo $ra > /sys/block/vdb/queue/read_ahead_kb; echo 3 > /mnt/proc/sys/vm/drop_caches
  s=$(date +%s%N 2>/dev/null || date +%s); find / -xdev -type f -path "/usr/*" -exec cat {} + >/dev/null 2>&1; e=$(date +%s%N 2>/dev/null || date +%s)
  echo "small-file walk ra=$ra: $(( (e-s)/1000000 )) ms"
done
} 2>&1 | sed 's/^/P| /'
echo PROBE_DONE
sleep 100000
