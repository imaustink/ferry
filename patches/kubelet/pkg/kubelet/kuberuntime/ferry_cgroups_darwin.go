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

// Stand-ins for the host-cgroup queries in the derived darwin copy of
// kuberuntime_container_linux.go. They describe the *host*, which here is macOS
// and has no cgroups at all, so each answers in the negative. None of this
// affects what the guest gets: a pod's resource limits and security context are
// carried in the CRI config and enforced inside its VM.
//
// See build-kubelet.sh, which rewrites the call sites.
package kuberuntime

import (
	"fmt"

	v1 "k8s.io/api/core/v1"
	"k8s.io/kubernetes/pkg/kubelet/cm"
)

// ferryHugePageSizes reports the page sizes the host offers. macOS exposes no
// hugepage cgroup controller, so a pod cannot request one.
func ferryHugePageSizes() []string { return nil }

// ferryParseCgroupFile stands in for reading /proc/self/cgroup, which does not
// exist here. Only the swap controller probe calls it, and swap accounting is
// not available on this platform either.
func ferryParseCgroupFile() (map[string]string, error) {
	return nil, fmt.Errorf("cgroups are not available on darwin")
}

// ferryApplyPodLevelMemoryHigh stands in for cm.ApplyPodLevelMemoryHigh, which
// upstream declares only in the linux build of package cm. Called from v1.37.
//
// It is a no-op, which is what upstream itself does on every platform that is
// not Linux. memory.high is a throttling threshold written to a pod's cgroup,
// and ferry's pod boundary is a virtual machine: what bounds a pod here is the
// memory that VM was created with, decided at sandbox creation, and there is no
// host pod cgroup for a threshold to be written to.
func ferryApplyPodLevelMemoryHigh(_ *v1.Pod, _ *cm.ResourceConfig, _ float64) {}
