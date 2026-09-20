//go:build darwin

/*
Copyright 2016 The Kubernetes Authors.

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

// Reading a container's cpu cgroup values back into Kubernetes quantities.
//
// From v1.36 the derived darwin copy of kuberuntime_container_linux.go calls
// these from toKubeContainerResources, which turns what the runtime reports in
// ContainerResources.Linux into the resources on a pod's status. The numbers
// arriving there are the *guest's* cgroup values -- cpu.shares, cpu.cfs_quota_us
// and cpu.cfs_period_us, read from a Linux kernel inside the VM -- so they have
// to be converted with Linux's own constants.
//
// The package already declares MinShares, SharesPerCPU and MilliCPUToCPU on
// darwin, in helpers_unsupported.go, and declares them as 0: that file describes
// a host with no cgroups, which is the right answer for everything that manages
// the *host's* hierarchy and the wrong one here. Using them would not merely
// round badly. SharesToMilliCPU would evaluate ceil(shares*0 / 0) -- a division
// by zero producing NaN -- and QuotaToMilliCPU would return 0, which reads as
// "no limit" and would quietly drop cpu from every pod's reported resources.
//
// So the conversions carry their own constants rather than the package's, named
// to make clear which platform they describe. They are upstream's values from
// pkg/kubelet/cm/helpers_linux.go.
package cm

import "math"

const (
	// What Linux uses, which is what the guest is.
	ferryLinuxMinShares     = 2
	ferryLinuxSharesPerCPU  = 1024
	ferryLinuxMilliCPUToCPU = 1000
)

// SharesToMilliCPU converts CpuShares (cpu.shares) to milli-CPU value.
func SharesToMilliCPU(shares int64) int64 {
	milliCPU := int64(0)
	if shares >= int64(ferryLinuxMinShares) {
		milliCPU = int64(math.Ceil(float64(shares*ferryLinuxMilliCPUToCPU) / float64(ferryLinuxSharesPerCPU)))
	}
	return milliCPU
}

// QuotaToMilliCPU converts cpu.cfs_quota_us and cpu.cfs_period_us to milli-CPU value.
func QuotaToMilliCPU(quota int64, period int64) int64 {
	if quota == -1 {
		return int64(0)
	}
	return (quota * ferryLinuxMilliCPUToCPU) / period
}
