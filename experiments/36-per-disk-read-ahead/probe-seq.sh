# Sequential reads of a 256 MiB file on a writable disk against read-ahead:
# the scratch disk, a sparse ext4 image on the Mac -- the same kind of disk an
# emptyDir or a block claim is. The guest's cache is dropped before each read;
# the Mac's is not (the guest just wrote the file through it). Five rounds,
# values interleaved. Needs -privileged.
sleep 3
{
mkdir -p /mnt/proc && mount -t proc proc /mnt/proc
dd if=/dev/urandom of=/blob bs=1M count=256 2>/dev/null; sync
for i in 1 2 3 4 5; do
  for ra in ${RAS:-128 1024 2048 4096 8192}; do
    for bs in 1024 64; do
      echo $ra > /sys/block/vdc/queue/read_ahead_kb
      echo 3 > /mnt/proc/sys/vm/drop_caches
      echo "pass=volume ra=$ra bs=${bs}k $(dd if=/blob of=/dev/null bs=${bs}k 2>&1 | tail -1)"
    done
  done
done
} 2>&1 | sed 's/^/P| /'
echo PROBE_DONE
sleep 100000
