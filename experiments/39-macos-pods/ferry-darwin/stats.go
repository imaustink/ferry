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
#include <mach/mach_time.h>
#include <stdlib.h>
#include <fcntl.h>

// punchHole frees the blocks of [off, off+len) in an open file, which reads as
// zeros afterwards, without moving its size or anyone's offset in it.
static int punchHole(int fd, long long off, long long len) {
    struct fpunchhole p = {0, 0, off, len};
    return fcntl(fd, F_PUNCHHOLE, &p);
}

// sumPgrp sums CPU (nanoseconds) and memory (bytes) over process group pgid,
// and returns how many processes it found, or a negative number on error.
//
// ri_user_time and ri_system_time are documented as nanoseconds but are in mach
// absolute-time units on Apple Silicon -- ~42x smaller than nanoseconds -- so a
// busy core reads as 0.02 "cores" until converted through mach_timebase_info.
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
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    *cpu = c * tb.numer / tb.denom; // mach units -> nanoseconds
    *mem = m;
    return count;
}
*/
import "C"

import "fmt"

// punchHole frees [off, off+n) of f's blocks (tail.go).
func punchHole(fd uintptr, off, n int64) error {
	if C.punchHole(C.int(fd), C.longlong(off), C.longlong(n)) != 0 {
		return fmt.Errorf("F_PUNCHHOLE failed")
	}
	return nil
}

// procStats is cumulative CPU nanoseconds and current memory bytes for the
// process group pgid, or ok=false when the group is gone.
func procStats(pgid int) (cpuNanos, memBytes uint64, ok bool) {
	var c, m C.ulonglong
	if n := C.sumPgrp(C.int(pgid), &c, &m); n <= 0 {
		return 0, 0, false
	}
	return uint64(c), uint64(m), true
}
