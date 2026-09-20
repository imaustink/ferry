//go:build darwin

/*
Copyright 2015 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// The v1.37 copy of the shared shim in patches/kubelet/, which serves every
// minor before it. Two things forced a whole file rather than a constructor
// beside it, the way the other minors manage:
//
//   - cadvisor folded info/v1 and info/v2 into one lib/model package. The v1
//     names won, except that v1's machine-level FsInfo became FilesystemInfo so
//     v2's per-filesystem one could keep the shorter name. An import path is
//     not something a second file can override.
//   - MachineInfo now takes a klog.Logger, and it is a method on the type the
//     rest of this file defines.
//
// Nothing about the macOS behaviour differs. If this and patches/kubelet/'s
// copy ever disagree about what the Mac reports, that is a bug in one of them.
//
// Machine facts on macOS come from sysctl and statfs. Per-container statistics
// deliberately do not: on this platform every pod is its own virtual machine,
// so the runtime -- not a cgroup walker on the host -- is the only thing that
// can see inside one. Those calls return empty and the kubelet is expected to
// source container stats from the CRI instead.
package cadvisor

/*
#include <mach/mach.h>
#include <mach/mach_host.h>

// ferry_cpu_ticks reads the machine's cumulative CPU time.
//
// macOS publishes no sysctl for this -- there is no kern.cp_time here as there
// is on the BSDs, and no /proc/stat as there is on Linux -- so the host port is
// the only way to ask. The counters are in ticks of 1/CLK_TCK of a second,
// summed across every core, and they only ever go up, which is what a cumulative
// usage metric needs.
static int ferry_cpu_ticks(unsigned long long *out) {
	host_cpu_load_info_data_t info;
	mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
	if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO,
	                    (host_info_t)&info, &count) != KERN_SUCCESS) {
		return -1;
	}
	out[0] = info.cpu_ticks[CPU_STATE_USER];
	out[1] = info.cpu_ticks[CPU_STATE_SYSTEM];
	out[2] = info.cpu_ticks[CPU_STATE_NICE];
	return 0;
}
*/
import "C"

import (
	"context"
	"fmt"
	"os"
	"runtime"
	"time"

	cadvisorapi "github.com/google/cadvisor/lib/model"
	"golang.org/x/sys/unix"
	"k8s.io/klog/v2"
)

type cadvisorDarwin struct {
	rootPath string
}

var _ Interface = new(cadvisorDarwin)

// New lives in ferry_new_darwin.go, per minor: its signature moves.

func (c *cadvisorDarwin) Start() error { return nil }

// ContainerInfoV2 describes a cgroup subtree. Only the root is answerable on
// this platform, and it has to be: the eviction manager polls the root every
// ten seconds to decide whether the node is under memory pressure, and an
// error there leaves eviction permanently blind. Machine-wide memory from the
// VM statistics stands in for the root cgroup's accounting.
//
// Any other name is a real cgroup path, which does not exist here. Those
// return empty rather than an error so per-container stats fall to the CRI,
// which is the only thing that can see inside a pod's VM.
func (c *cadvisorDarwin) ContainerInfoV2(name string, options cadvisorapi.RequestOptions) (map[string]cadvisorapi.ContainerInfo, error) {
	if name != "/" {
		return map[string]cadvisorapi.ContainerInfo{}, nil
	}

	total, err := unix.SysctlUint64("hw.memsize")
	if err != nil {
		return nil, fmt.Errorf("read hw.memsize: %w", err)
	}
	used := total - freeMemoryBytes()

	now := time.Now()
	return map[string]cadvisorapi.ContainerInfo{
		"/": {
			Spec: cadvisorapi.ContainerSpec{
				CreationTime: bootTime(),
				HasMemory:    true,
				HasCpu:       true,
				Memory:       cadvisorapi.MemorySpec{Limit: total},
			},
			Stats: []*cadvisorapi.ContainerStats{{
				Timestamp: now,
				Cpu: &cadvisorapi.CpuStats{
					Usage: cadvisorapi.CpuUsage{Total: machineCPUNanoseconds()},
				},
				Memory: &cadvisorapi.MemoryStats{
					Usage:      used,
					WorkingSet: used,
					RSS:        used,
				},
			}},
		},
	}, nil
}

// machineCPUNanoseconds reports how much CPU time this Mac has spent since boot.
//
// The kubelet turns the root "cgroup"'s cumulative CPU into the node's
// node_cpu_usage_seconds_total, which is what metrics-server rates to answer
// `kubectl top nodes`. Leaving it at zero did not simply lose a number:
// metrics-server discards a node sample whose cumulative CPU is zero, so the
// node vanished from the metrics API entirely and `kubectl top nodes` failed
// with "metrics not available yet" while `kubectl top pods` worked.
//
// Idle time is deliberately not counted -- this is time spent, not time
// available. A failed read yields zero, which puts the node back in the state
// this function exists to fix, and is still better than a wrong number.
func machineCPUNanoseconds() uint64 {
	var ticks [3]C.ulonglong
	if C.ferry_cpu_ticks(&ticks[0]) != 0 {
		return 0
	}
	// CLK_TCK is 100 on Darwin and is not exposed as a sysctl; the constant is
	// part of the platform's ABI rather than a property of this machine.
	const nanosecondsPerTick = uint64(time.Second) / 100
	return (uint64(ticks[0]) + uint64(ticks[1]) + uint64(ticks[2])) * nanosecondsPerTick
}

// freeMemoryBytes reports memory macOS considers immediately available. A
// failed read yields zero, which makes the node look fully used -- the
// conservative direction for an eviction decision.
//
// Free pages alone are not that number. macOS deliberately keeps very few of
// them and holds everything else as cache, so a machine with gigabytes to spare
// reports a few hundred megabytes free and the kubelet taints the node
// MemoryPressure with nothing actually wrong. That is what Linux's MemAvailable
// exists to avoid.
//
// Purgeable, reusable and speculative pages are the ones the kernel can take
// back without writing anything out, so they are counted too. Inactive pages
// are also usually reclaimable and are deliberately left out: macOS exposes no
// sysctl for them, and a lower bound is the right kind of wrong here.
func freeMemoryBytes() uint64 {
	pageSize, err := unix.SysctlUint32("hw.pagesize")
	if err != nil || pageSize == 0 {
		return 0
	}
	freePages, err := unix.SysctlUint32("vm.page_free_count")
	if err != nil {
		return 0
	}
	pages := uint64(freePages)
	// Best effort: a counter this kernel does not publish just does not count.
	for _, name := range []string{
		"vm.page_purgeable_count",
		"vm.page_reusable_count",
		"vm.page_speculative_count",
	} {
		if reclaimable, err := unix.SysctlUint32(name); err == nil {
			pages += uint64(reclaimable)
		}
	}
	return pages * uint64(pageSize)
}

// bootTime reports when the machine came up, used as the root's creation time.
func bootTime() time.Time {
	tv, err := unix.SysctlTimeval("kern.boottime")
	if err != nil {
		return time.Time{}
	}
	return time.Unix(tv.Sec, int64(tv.Usec)*1000)
}

func (c *cadvisorDarwin) GetRequestedContainersInfo(containerName string, options cadvisorapi.RequestOptions) (map[string]*cadvisorapi.ContainerInfo, error) {
	return map[string]*cadvisorapi.ContainerInfo{}, nil
}

func (c *cadvisorDarwin) MachineInfo(_ klog.Logger) (*cadvisorapi.MachineInfo, error) {
	memBytes, err := unix.SysctlUint64("hw.memsize")
	if err != nil {
		return nil, fmt.Errorf("read hw.memsize: %w", err)
	}

	// hw.cpufrequency is absent on Apple silicon; a zero frequency is
	// acceptable to the kubelet, so treat a failed read as unknown.
	cpuKHz, err := unix.SysctlUint64("hw.cpufrequency")
	if err != nil {
		cpuKHz = 0
	} else {
		cpuKHz /= 1000
	}

	physical := runtime.NumCPU()
	if n, err := unix.SysctlUint32("hw.physicalcpu"); err == nil && n > 0 {
		physical = int(n)
	}

	// IOPlatformUUID is the closest stable per-machine identifier available
	// without elevated privileges; it is reused for all three id fields since
	// macOS exposes no separate boot id.
	uuid, err := unix.Sysctl("kern.uuid")
	if err != nil {
		uuid = ""
	}

	fsInfo, err := c.fsInfo(c.rootPath)
	if err != nil {
		return nil, err
	}

	return &cadvisorapi.MachineInfo{
		NumCores:         runtime.NumCPU(),
		NumPhysicalCores: physical,
		NumSockets:       1,
		CpuFrequency:     cpuKHz,
		MemoryCapacity:   memBytes,
		MachineID:        uuid,
		SystemUUID:       uuid,
		BootID:           uuid,
		Filesystems: []cadvisorapi.FilesystemInfo{{
			Device:    c.rootPath,
			Type:      "vfs",
			Capacity:  fsInfo.Capacity,
			Inodes:    inodesOrZero(fsInfo.Inodes),
			HasInodes: fsInfo.Inodes != nil,
		}},
	}, nil
}

func (c *cadvisorDarwin) VersionInfo() (*cadvisorapi.VersionInfo, error) {
	release, err := unix.Sysctl("kern.osrelease")
	if err != nil {
		release = "unknown"
	}
	version, err := unix.Sysctl("kern.osproductversion")
	if err != nil {
		version = "unknown"
	}
	return &cadvisorapi.VersionInfo{
		KernelVersion:      release,
		ContainerOsVersion: "macOS " + version,
		CadvisorVersion:    "",
		CadvisorRevision:   "",
	}, nil
}

func (c *cadvisorDarwin) ImagesFsInfo(context.Context) (cadvisorapi.FsInfo, error) {
	return c.fsInfo(c.rootPath)
}

func (c *cadvisorDarwin) RootFsInfo() (cadvisorapi.FsInfo, error) {
	return c.fsInfo("/")
}

func (c *cadvisorDarwin) ContainerFsInfo(context.Context) (cadvisorapi.FsInfo, error) {
	return c.fsInfo(c.rootPath)
}

func (c *cadvisorDarwin) GetDirFsInfo(path string) (cadvisorapi.FsInfo, error) {
	return c.fsInfo(path)
}

// fsInfo reports usage for the filesystem backing path. The path may not exist
// yet during early kubelet startup, so fall back to its nearest existing
// ancestor rather than failing the call.
func (c *cadvisorDarwin) fsInfo(path string) (cadvisorapi.FsInfo, error) {
	probe := path
	for probe != "/" && probe != "." && probe != "" {
		if _, err := os.Stat(probe); err == nil {
			break
		}
		probe = parentDir(probe)
	}
	if probe == "" || probe == "." {
		probe = "/"
	}

	var st unix.Statfs_t
	if err := unix.Statfs(probe, &st); err != nil {
		return cadvisorapi.FsInfo{}, fmt.Errorf("statfs %s: %w", probe, err)
	}

	bsize := uint64(st.Bsize)
	capacity := st.Blocks * bsize
	available := st.Bavail * bsize
	return cadvisorapi.FsInfo{
		Device:     probe,
		Mountpoint: probe,
		Capacity:   capacity,
		Available:  available,
		Usage:      capacity - st.Bfree*bsize,
		Inodes:     &st.Files,
		InodesFree: &st.Ffree,
	}, nil
}

func inodesOrZero(n *uint64) uint64 {
	if n == nil {
		return 0
	}
	return *n
}

func parentDir(p string) string {
	for i := len(p) - 1; i > 0; i-- {
		if p[i] == '/' {
			return p[:i]
		}
	}
	return "/"
}

// IsPsiEnabled reports whether the kernel exposes pressure stall information.
// Asked for from v1.36, by the summary server deciding whether to serve PSI
// metrics. PSI is a Linux kernel feature read from /proc/pressure, and the host
// here is macOS, so the answer is no. This describes the host: a pod's own
// pressure metrics, if anything ever wants them, come from the guest.
func IsPsiEnabled(logger klog.Logger) bool { return false }
