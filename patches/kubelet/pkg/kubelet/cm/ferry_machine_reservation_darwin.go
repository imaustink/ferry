//go:build darwin

/*
Copyright 2026 The Kubernetes Authors.

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

// The Mac node and the machines it hosts are drawn from one pool of memory,
// and without this the scheduler was told about it twice: the Mac node
// advertised every byte of RAM, and each machine advertised its own memory on
// top. A Mac with 16 GiB of machines could still be promised 32 GiB of pod VMs
// on a 32 GiB Mac.
//
// So the memory committed to machines is reserved out of the Mac node's
// allocatable. ferry-machined writes the total -- the sum of every Machine's
// spec.memory, in bytes -- to the file FERRY_MACHINE_MEMORY_FILE names, and
// the kubelet reads it on every node status update, which is the one place
// upstream asks for the reservation. A machine appearing shrinks the Mac node
// within one update; one going away gives the memory back the same way.
//
// Nothing is enforced. enforceNodeAllocatable is empty on darwin, so pods
// already running on the Mac are never evicted when a machine arrives; the
// reservation only stops new ones being scheduled into memory a machine holds.
// ferry-karpenter counts the Mac's pods before it makes a machine, which is
// the other half of the same ledger.
//
// Shared across minors: GetNodeAllocatableReservation has not changed shape
// since the interface gained it.
package cm

import (
	"os"
	"strconv"
	"strings"

	v1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	"k8s.io/klog/v2"
)

// GetNodeAllocatableReservation is what node status subtracts from capacity to
// get allocatable. The stub reserves nothing.
func (cm *darwinContainerManager) GetNodeAllocatableReservation() v1.ResourceList {
	bytes, ok := machineMemoryReserved(os.Getenv("FERRY_MACHINE_MEMORY_FILE"))
	if !ok {
		return nil
	}
	return v1.ResourceList{
		v1.ResourceMemory: *resource.NewQuantity(bytes, resource.BinarySI),
	}
}

// machineMemoryReserved reads the ledger. No file is no machines -- a Mac that
// joined, machines turned off, or a node that is not the one hosting them --
// and reserves nothing, which is what every Mac node did before this.
func machineMemoryReserved(path string) (int64, bool) {
	if path == "" {
		return 0, false
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if !os.IsNotExist(err) {
			klog.ErrorS(err, "Failed to read the memory committed to machines; reserving none", "path", path)
		}
		return 0, false
	}
	bytes, err := strconv.ParseInt(strings.TrimSpace(string(data)), 10, 64)
	if err != nil || bytes < 0 {
		klog.ErrorS(err, "Memory committed to machines is not a byte count; reserving none", "path", path, "content", string(data))
		return 0, false
	}
	return bytes, true
}
