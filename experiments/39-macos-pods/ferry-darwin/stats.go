package main

// Per-container CPU and memory, for `kubectl top`, metrics-server and the
// kubelet's summary API.
//
// A Linux runtime reads a container's cgroup. There is no cgroup here: a
// container is a process group (StartContainer sets Setpgid, so the group's id
// is the container's pid). So the numbers come from the group's processes,
// through libproc -- proc_listpids for the group's members and proc_pid_rusage
// for each -- summed. ri_user_time + ri_system_time is cumulative CPU in
// nanoseconds, which is exactly the counter UsageCoreNanoSeconds wants; the
// kubelet differences it over time for a rate. ri_phys_footprint is the memory
// Activity Monitor shows, the closest macOS has to a working set.

/*
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <stdlib.h>

// sumPgrp sums CPU (nanoseconds) and memory (bytes) over process group pgid,
// and returns how many processes it found, or a negative number on error.
static int sumPgrp(int pgid, unsigned long long *cpu, unsigned long long *mem) {
    int size = proc_listpids(PROC_PGRP_ONLY, (uint32_t)pgid, NULL, 0);
    if (size <= 0) return size;
    int cap = size / (int)sizeof(pid_t) + 16;
    pid_t *pids = calloc(cap, sizeof(pid_t));
    if (!pids) return -1;
    int got = proc_listpids(PROC_PGRP_ONLY, (uint32_t)pgid, pids, (int)(cap * sizeof(pid_t)));
    if (got <= 0) { free(pids); return got; }
    int count = got / (int)sizeof(pid_t);
    unsigned long long c = 0, m = 0;
    for (int i = 0; i < count; i++) {
        if (pids[i] <= 0) continue;
        struct rusage_info_v2 ri;
        if (proc_pid_rusage(pids[i], RUSAGE_INFO_V2, (rusage_info_t *)&ri) == 0) {
            c += ri.ri_user_time + ri.ri_system_time;
            m += ri.ri_phys_footprint;
        }
    }
    free(pids);
    *cpu = c;
    *mem = m;
    return count;
}
*/
import "C"

// procStats is cumulative CPU nanoseconds and current memory bytes for the
// process group pgid, or ok=false when the group is gone.
func procStats(pgid int) (cpuNanos, memBytes uint64, ok bool) {
	var c, m C.ulonglong
	if n := C.sumPgrp(C.int(pgid), &c, &m); n <= 0 {
		return 0, 0, false
	}
	return uint64(c), uint64(m), true
}
