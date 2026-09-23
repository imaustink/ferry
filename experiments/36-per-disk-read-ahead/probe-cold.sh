# Cold sequential reads of /big, a 2 GiB random file in the image, against
# read-ahead. Cold in both kernels: seq-cold.sh gives the image's ext4 a fresh
# APFS clone before each pod, so the Mac has none of it cached either, and
# each (read-ahead, block size) pair reads a 192 MiB stretch no one has read.
# Then the same stretches again with only the guest's cache dropped.
# Needs -privileged. ORDER is filled in by seq-cold.sh.
sleep 2
{
mkdir -p /mnt/proc && mount -t proc proc /mnt/proc
for pass in cold warm; do
  slot=0
  for ra in ORDER; do
    for bs in 1024 64; do
      echo $ra > /sys/block/vdb/queue/read_ahead_kb
      echo 3 > /mnt/proc/sys/vm/drop_caches
      count=$(( 192 * 1024 / bs ))
      echo "pass=$pass ra=$ra bs=${bs}k $(dd if=/big of=/dev/null bs=${bs}k count=$count skip=$(( slot * count )) 2>&1 | tail -1)"
      slot=$((slot + 1))
    done
  done
done
} 2>&1 | sed 's/^/P| /'
echo PROBE_DONE
sleep 100000
