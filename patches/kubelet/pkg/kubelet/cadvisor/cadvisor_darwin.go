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

// Machine facts on macOS come from sysctl and statfs. Per-container statistics
// deliberately do not: on this platform every pod is its own virtual machine,
// so the runtime -- not a cgroup walker on the host -- is the only thing that
// can see inside one. Those calls return empty and the kubelet is expected to
// source container stats from the CRI instead.
package cadvisor

import (
	"context"
	"fmt"
	"os"
	"runtime"
	"time"

	cadvisorapi "github.com/google/cadvisor/info/v1"
	cadvisorapiv2 "github.com/google/cadvisor/info/v2"
	"golang.org/x/sys/unix"
)

type cadvisorDarwin struct {
	rootPath string
}

var _ Interface = new(cadvisorDarwin)

func New(imageFsInfoProvider ImageFsInfoProvider, rootPath string, cgroupsRoots []string, usingLegacyStats, localStorageCapacityIsolation bool) (Interface, error) {
	return &cadvisorDarwin{rootPath: rootPath}, nil
}

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
func (c *cadvisorDarwin) ContainerInfoV2(name string, options cadvisorapiv2.RequestOptions) (map[string]cadvisorapiv2.ContainerInfo, error) {
	if name != "/" {
		return map[string]cadvisorapiv2.ContainerInfo{}, nil
	}

	total, err := unix.SysctlUint64("hw.memsize")
	if err != nil {
		return nil, fmt.Errorf("read hw.memsize: %w", err)
	}
	used := total - freeMemoryBytes()

	now := time.Now()
	return map[string]cadvisorapiv2.ContainerInfo{
		"/": {
			Spec: cadvisorapiv2.ContainerSpec{
				CreationTime: bootTime(),
				HasMemory:    true,
				HasCpu:       true,
				Memory:       cadvisorapiv2.MemorySpec{Limit: total},
			},
			Stats: []*cadvisorapiv2.ContainerStats{{
				Timestamp: now,
				Cpu:       &cadvisorapi.CpuStats{},
				Memory: &cadvisorapi.MemoryStats{
					Usage:      used,
					WorkingSet: used,
					RSS:        used,
				},
			}},
		},
	}, nil
}

// freeMemoryBytes reports memory macOS considers immediately available. A
// failed read yields zero, which makes the node look fully used -- the
// conservative direction for an eviction decision.
func freeMemoryBytes() uint64 {
	pageSize, err := unix.SysctlUint32("hw.pagesize")
	if err != nil || pageSize == 0 {
		return 0
	}
	freePages, err := unix.SysctlUint32("vm.page_free_count")
	if err != nil {
		return 0
	}
	return uint64(freePages) * uint64(pageSize)
}

// bootTime reports when the machine came up, used as the root's creation time.
func bootTime() time.Time {
	tv, err := unix.SysctlTimeval("kern.boottime")
	if err != nil {
		return time.Time{}
	}
	return time.Unix(tv.Sec, int64(tv.Usec)*1000)
}

func (c *cadvisorDarwin) GetRequestedContainersInfo(containerName string, options cadvisorapiv2.RequestOptions) (map[string]*cadvisorapi.ContainerInfo, error) {
	return map[string]*cadvisorapi.ContainerInfo{}, nil
}

func (c *cadvisorDarwin) MachineInfo() (*cadvisorapi.MachineInfo, error) {
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
		Filesystems: []cadvisorapi.FsInfo{{
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

func (c *cadvisorDarwin) ImagesFsInfo(context.Context) (cadvisorapiv2.FsInfo, error) {
	return c.fsInfo(c.rootPath)
}

func (c *cadvisorDarwin) RootFsInfo() (cadvisorapiv2.FsInfo, error) {
	return c.fsInfo("/")
}

func (c *cadvisorDarwin) ContainerFsInfo(context.Context) (cadvisorapiv2.FsInfo, error) {
	return c.fsInfo(c.rootPath)
}

func (c *cadvisorDarwin) GetDirFsInfo(path string) (cadvisorapiv2.FsInfo, error) {
	return c.fsInfo(path)
}

// fsInfo reports usage for the filesystem backing path. The path may not exist
// yet during early kubelet startup, so fall back to its nearest existing
// ancestor rather than failing the call.
func (c *cadvisorDarwin) fsInfo(path string) (cadvisorapiv2.FsInfo, error) {
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
		return cadvisorapiv2.FsInfo{}, fmt.Errorf("statfs %s: %w", probe, err)
	}

	bsize := uint64(st.Bsize)
	capacity := st.Blocks * bsize
	available := st.Bavail * bsize
	return cadvisorapiv2.FsInfo{
		Device:    probe,
		Mountpoint: probe,
		Capacity:  capacity,
		Available: available,
		Usage:     capacity - st.Bfree*bsize,
		Inodes:    &st.Files,
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
