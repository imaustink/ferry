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

// Converting between a container's cpu cgroup values and Kubernetes quantities.
//
// Both directions are here, and they failed in different ways.
//
// Writing came first and was silently broken from the beginning. The derived
// darwin copy builds LinuxContainerResources from cm.MilliCPUToShares and
// cm.MilliCPUToQuota, which on this platform are helpers_unsupported.go's and
// return 0. Every container therefore reached the runtime asking for
// CpuShares: 0, CpuQuota: 0 -- a CRI message that says the container has no
// CPU limit at all, whatever its pod spec said.
//
// What that cost is a cgroup inside the pod's VM, not the size of the VM: the
// machine is sized once at sandbox creation, from the pod spec, which ferry-cri
// reads through ferry-streamer precisely because CRI carries resources per
// container and never for the pod. So the pod was the right size and the
// containers inside it were unbounded, each free to take the whole machine
// regardless of the limit Kubernetes had granted it.
//
// The Ferry-prefixed pair below does the real arithmetic; build-kubelet.sh
// rewrites the call sites, because the unsupported file is still compiled here
// and owns the unprefixed names.
//
// Reading back is the case below. From v1.36 the derived copy calls
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

import (
	"math"

	utilfeature "k8s.io/apiserver/pkg/util/feature"
	kubefeatures "k8s.io/kubernetes/pkg/features"
)

const (
	// What Linux uses, which is what the guest is.
	ferryLinuxMinShares      = 2
	ferryLinuxMaxShares      = 262144
	ferryLinuxSharesPerCPU   = 1024
	ferryLinuxMilliCPUToCPU  = 1000
	ferryLinuxMinQuotaPeriod = 1000

	// FerryQuotaPeriod is cfs_period_us, 100ms in microseconds. It stands in
	// for cm.QuotaPeriod, which helpers_unsupported.go declares as 0.
	FerryQuotaPeriod = 100000
)

// FerryMilliCPUToQuota converts milliCPU to CFS quota and period values.
// Input parameters and resulting value is number of microseconds.
func FerryMilliCPUToQuota(milliCPU int64, period int64) (quota int64) {
	if milliCPU == 0 {
		return
	}

	if !utilfeature.DefaultFeatureGate.Enabled(kubefeatures.CPUCFSQuotaPeriod) {
		period = FerryQuotaPeriod
	}

	quota = (milliCPU * period) / ferryLinuxMilliCPUToCPU

	// quota needs to be a minimum of 1ms.
	if quota < ferryLinuxMinQuotaPeriod {
		quota = ferryLinuxMinQuotaPeriod
	}
	return
}

// FerryMilliCPUToShares converts the milliCPU to CFS shares.
func FerryMilliCPUToShares(milliCPU int64) uint64 {
	if milliCPU == 0 {
		// The kernel default for unset is 1024; 2 is the real floor.
		return ferryLinuxMinShares
	}
	shares := (milliCPU * ferryLinuxSharesPerCPU) / ferryLinuxMilliCPUToCPU
	if shares < ferryLinuxMinShares {
		return ferryLinuxMinShares
	}
	if shares > ferryLinuxMaxShares {
		return ferryLinuxMaxShares
	}
	return uint64(shares)
}

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
