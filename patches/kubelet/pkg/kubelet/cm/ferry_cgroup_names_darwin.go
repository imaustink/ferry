//go:build darwin

/*
Copyright 2017 The Kubernetes Authors.

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

// cgroup v2 file names, which upstream declares in cgroup_manager_linux.go.
// They are needed here only because the darwin build reuses the container
// config generation from that platform, and it names these files when the
// MemoryQoS feature is on. MemoryQoS is never on here -- it requires cgroup v2
// on the host, and the host is macOS -- so these are referenced but not acted
// upon. They are declared rather than stripped so the derived file stays a
// faithful copy of upstream.
package cm

const (
	// Cgroup2MemoryMin is memory.min for cgroup v2
	Cgroup2MemoryMin string = "memory.min"
	// Cgroup2MemoryHigh is memory.high for cgroup v2
	Cgroup2MemoryHigh string = "memory.high"
	// Cgroup2MaxSwapFilename is memory.swap.max for cgroup v2
	Cgroup2MaxSwapFilename string = "memory.swap.max"
)
