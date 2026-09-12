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
// So this is the upstream stub with a working Start(). It is deliberately not
// a port of container_manager_linux.go.
package cm

import (
	"k8s.io/klog/v2"
	"k8s.io/mount-utils"

	clientset "k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/record"
	"k8s.io/kubernetes/pkg/kubelet/cadvisor"
)

func NewContainerManager(_ mount.Interface, _ cadvisor.Interface, nodeConfig NodeConfig, failSwapOn bool, recorder record.EventRecorder, kubeClient clientset.Interface) (ContainerManager, error) {
	if nodeConfig.CgroupsPerQOS {
		klog.InfoS("cgroupsPerQOS is set but there is no cgroup hierarchy on darwin; pod resource limits are enforced by the runtime instead")
	}
	return NewStubContainerManager(), nil
}
