# Which files the guest's page cache holds, and why. Needs -privileged: it
# mounts vminitd's own filesystem a second time, which shares the first
# mount's superblock and so its page cache, and asks mincore what is resident.
sleep ${PROBE_DELAY:-5}
{
for d in vda vdb; do echo "$d ra_kb=$(cat /sys/block/$d/queue/read_ahead_kb) max_kb=$(cat /sys/block/$d/queue/max_sectors_kb) io_opt=$(cat /sys/block/$d/queue/optimal_io_size) bs=$(cat /sys/block/$d/queue/logical_block_size)"; done
grep -E "^(Cached|MemFree|Mapped)" /proc/meminfo
cat /proc/diskstats | awk '$4>0 {print $3, "read_MiB", $6/2048, "reads", $4}'
for f in /sys/bus/virtio/devices/*; do echo "$(basename $f) dev=$(cat $f/device) features=$(cat $f/features)"; done
apk add -q util-linux-misc >/dev/null 2>&1 || echo "apk failed"
mkdir -p /mnt/init && mount -o ro -t ext4 /dev/vda /mnt/init && echo mounted
fincore -b /mnt/init/sbin/vminitd /mnt/init/sbin/vmexec 2>&1
} 2>&1 | sed 's/^/P| /'
echo PROBE_DONE
sleep 100000
