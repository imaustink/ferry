//go:build !darwin

package prober

// Everywhere else the kubelet shares a network namespace view with its pods and
// can reach them at the address the cluster knows them by.
func ferryReachableAddress(podIP string) string { return podIP }
