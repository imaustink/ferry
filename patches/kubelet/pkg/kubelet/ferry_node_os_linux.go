//go:build !darwin

package kubelet

import goruntime "runtime"

// Everywhere else the kubelet's own OS is the containers' OS.
func ferryContainerOS() string { return goruntime.GOOS }
