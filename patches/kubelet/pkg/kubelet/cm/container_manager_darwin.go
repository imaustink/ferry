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

// The container manager owns the node's cgroup hierarchy: the QoS tiers, the
// per-pod cgroups, and the reservations carved out for kube and system daemons.
// None of that exists on macOS, and more to the point none of it belongs here:
// when every pod is a separate virtual machine, the hypervisor -- not a cgroup
// tree on the host -- is what bounds a pod's CPU and memory. Enforcement moves
// to VM sizing at sandbox creation, and cgroups v2 inside the guest bound the
// containers within a pod.
//
// So this is the upstream stub, with the one piece that is not about cgroups
// filled in: node capacity. It is deliberately not a port of
// container_manager_linux.go.
package cm

import (
	"k8s.io/klog/v2"
	"k8s.io/mount-utils"

	v1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	clientset "k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/record"
	"k8s.io/kubernetes/pkg/kubelet/cadvisor"
)

type darwinContainerManager struct {
	// The stub supplies the cgroup-shaped surface, all of which is inert here.
	ContainerManager
	cadvisor cadvisor.Interface
}

func NewContainerManager(_ mount.Interface, ci cadvisor.Interface, nodeConfig NodeConfig, failSwapOn bool, recorder record.EventRecorder, kubeClient clientset.Interface) (ContainerManager, error) {
	if nodeConfig.CgroupsPerQOS {
		klog.InfoS("cgroupsPerQOS is set but there is no cgroup hierarchy on darwin; pod resource limits are enforced by the runtime instead")
	}
	return &darwinContainerManager{
		ContainerManager: NewStubContainerManager(),
		cadvisor:         ci,
	}, nil
}

// GetCapacity reports node capacity for resources the container manager owns.
// The stub returns zero for ephemeral storage, which makes the node advertise
// no disk at all; report the real filesystem instead so the scheduler can
// honour ephemeral-storage requests.
func (cm *darwinContainerManager) GetCapacity(localStorageCapacityIsolation bool) v1.ResourceList {
	if !localStorageCapacityIsolation {
		return v1.ResourceList{}
	}
	rootfs, err := cm.cadvisor.RootFsInfo()
	if err != nil {
		klog.ErrorS(err, "Failed to read root filesystem capacity; reporting no ephemeral storage")
		return v1.ResourceList{}
	}
	return v1.ResourceList{
		v1.ResourceEphemeralStorage: *resource.NewQuantity(int64(rootfs.Capacity), resource.BinarySI),
	}
}
