sleep ${PROBE_DELAY:-8}
{
echo "== cmdline"; cat /proc/cmdline
echo "== nproc"; nproc
echo "== meminfo"; cat /proc/meminfo
echo "== vmstat"; grep -E "^(nr_|workingset|pgpgin|pgfault)" /proc/vmstat
echo "== zoneinfo"; grep -E "^Node|present|managed|spanned" /proc/zoneinfo
echo "== buddy"; cat /proc/buddyinfo
echo "== slabinfo"; cat /proc/slabinfo 2>/dev/null | awk 'NR>2 {printf "%s %d\n", $1, $3*$4/1024}' | sort -k2 -n -r | head -25
echo "== procs"; for p in /proc/[0-9]*; do n=$(cat $p/comm 2>/dev/null); r=$(grep -E "^VmRSS" $p/status 2>/dev/null | awk '{print $2}'); [ -n "$r" ] && echo "$n $r"; done
echo "== mounts"; cat /proc/mounts
echo "== dmesg-mem"; dmesg 2>/dev/null | grep -iE "memory|reserved|crashkernel|swiotlb|cma|log_buf|percpu|Freeing" | head -40
echo "== diskstats"; cat /proc/diskstats | awk '$4>0 {print $3, "reads_sectors", $6, "write_sectors", $10}'
} 2>&1 | sed 's/^/P| /'
echo PROBE_DONE
sleep 100000
