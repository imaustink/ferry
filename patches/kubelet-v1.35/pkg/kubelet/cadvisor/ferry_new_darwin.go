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
// between minors. v1.35 still takes the v1.34 arguments -- the logger arrives
// in v1.36 -- even though NewContainerManager has already grown its context by
// this minor, which is why v1.35 needs an overlay of its own rather than
// reusing either neighbour's.
package cadvisor

func New(imageFsInfoProvider ImageFsInfoProvider, rootPath string, cgroupsRoots []string, usingLegacyStats, localStorageCapacityIsolation bool) (Interface, error) {
	return &cadvisorDarwin{rootPath: rootPath}, nil
}
