//go:build !darwin

package lifecycle

import "runtime"

// Everywhere else the kubelet's own OS is the containers' OS.
func ferryContainerOS() string { return runtime.GOOS }
