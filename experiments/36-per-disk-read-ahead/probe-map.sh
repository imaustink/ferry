# Which guest disk is which. Needs -privileged.
sleep 2
mkdir -p /mnt/proc && mount -t proc proc /mnt/proc 2>/dev/null
{
for d in /sys/block/vd*; do
  n=$(basename $d)
  echo "$n ro=$(cat $d/ro) MiB=$(( $(cat $d/size) / 2048 )) ra=$(cat $d/queue/read_ahead_kb) rot=$(cat $d/queue/rotational) serial=$(cat $d/serial 2>/dev/null)"
done
grep -E "vd|overlay" /mnt/proc/1/mounts
} 2>&1 | sed 's/^/P| /'
echo PROBE_DONE
sleep 100000
