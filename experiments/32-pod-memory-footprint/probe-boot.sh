# The guest's boot log and memory summary, whole.
sleep 3
{ cat /proc/cmdline; dmesg; grep -E "^(MemTotal|MemFree|Cached|AnonPages)" /proc/meminfo; } 2>&1 | sed 's/^/P| /'
echo PROBE_DONE
sleep 100000
