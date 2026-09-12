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

package kubelet

import "os"

// The default container log root is /var/log/containers, which on macOS is
// owned by the system and not writable without root. A kubelet installed as a
// launchd daemon runs as root and wants the default; a developer running one
// in a terminal does not. Honour an explicit override so both work without
// forking the path handling itself.
func init() {
	if dir := os.Getenv("K5S_CONTAINER_LOGS_DIR"); dir != "" {
		ContainerLogsDir = dir
	}
}
