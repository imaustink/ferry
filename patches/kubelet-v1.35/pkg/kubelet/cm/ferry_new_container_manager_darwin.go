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

// The constructor only, because its signature is the one thing here that moves
// between minors. v1.35 is where NewContainerManager grew its context, a minor
// before cadvisor.New grew its logger; nothing in the darwin implementation
// blocks, so the context is accepted and dropped, which is what upstream's own
// unsupported variant does.
package cm

import (
	"context"

	"k8s.io/client-go/tools/record"
	"k8s.io/klog/v2"
	"k8s.io/mount-utils"

	clientset "k8s.io/client-go/kubernetes"
	"k8s.io/kubernetes/pkg/kubelet/cadvisor"
)

func NewContainerManager(_ context.Context, _ mount.Interface, ci cadvisor.Interface, nodeConfig NodeConfig, failSwapOn bool, recorder record.EventRecorder, kubeClient clientset.Interface) (ContainerManager, error) {
	if nodeConfig.CgroupsPerQOS {
		klog.InfoS("cgroupsPerQOS is set but there is no cgroup hierarchy on darwin; pod resource limits are enforced by the runtime instead")
	}
	return &darwinContainerManager{
		ContainerManager: NewStubContainerManager(),
		cadvisor:         ci,
	}, nil
}
