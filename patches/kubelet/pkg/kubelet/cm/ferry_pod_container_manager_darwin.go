//go:build darwin

/*
Copyright 2024 The Kubernetes Authors.

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

// The pod's own cgroup, which on this platform does not exist.
//
// Everywhere else the kubelet puts a pod in a cgroup of its own, above the
// containers and below the QoS tier, and bounds the pod there. ferry's pod
// boundary is a virtual machine instead: what a pod may use is decided when its
// machine is created, and the containers inside it are bounded by cgroups in
// the guest. There is no host cgroup between the two for anything to read.
//
// The stub says all of that already -- every method is inert -- except for
// GetPodCgroupConfig, which reports `not implemented`. That is the right answer
// where an error is handled, and the wrong shape where one is not.
// convertToAPIPodLevelResourcesStatus calls it on every sync for every pod and
// only logs what comes back, so a node running six pods wrote twelve error
// lines a minute saying nothing was wrong:
//
//	kubelet_pods.go:2193] "failed to read memory cgroup config for the pod"
//	  err="not implemented" podName="cpu-limit-2"
//
// Answering `no configuration, no error` is both quieter and truer: the
// question has an answer here, and the answer is that there is no pod cgroup.
// Its callers already expect that -- every one of them tests the config for nil
// before reading it, because Windows has never had a pod cgroup either.
//
// It does not weaken the one place that must refuse. In-place pod resize asks
// ResourceConfigForPod for the configuration it would write *before* it reads
// the current one, and that returns nil on darwin, so doPodResizeAction still
// fails the resize with a message naming the reason. A VM cannot be resized
// after it boots, so that refusal is the correct outcome and it is reached
// first.
package cm

import (
	v1 "k8s.io/api/core/v1"
)

// ferryPodContainerManager is the stub, with the one question answered that
// the stub answers wrongly.
type ferryPodContainerManager struct {
	podContainerManagerStub
}

var _ PodContainerManager = &ferryPodContainerManager{}

// GetPodCgroupConfig reports what the pod's cgroup is set to. There is no pod
// cgroup on darwin, which is a fact and not a failure.
func (m *ferryPodContainerManager) GetPodCgroupConfig(_ *v1.Pod, _ v1.ResourceName) (*ResourceConfig, error) {
	return nil, nil
}

// NewPodContainerManager is declared here rather than in
// container_manager_darwin.go because that file is copied per-minor from v1.37
// on, and this does not vary. The stub's version is what the embedded
// ContainerManager would otherwise supply.
func (cm *darwinContainerManager) NewPodContainerManager() PodContainerManager {
	return &ferryPodContainerManager{}
}
