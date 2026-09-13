//go:build darwin

package kubelet

// The node's kubernetes.io/os label describes where containers run.
//
// On ferry the kubelet is a macOS process, so its GOOS is darwin -- but every
// container it starts runs on Linux, each inside its own virtual machine with
// its own Linux kernel. Nothing in the ecosystem schedules onto a darwin node:
// metrics-server, ingress-nginx and most Helm charts all carry
// `nodeSelector: kubernetes.io/os: linux`, and a literally truthful label would
// leave ferry unable to run the software people want to run.
//
// So the label says linux, which is true of the containers and is what the label
// is used for. The Mac is not hidden: `kubectl get nodes -o wide` reports macOS
// as the OS image, and the kernel version is the Mac's.
func ferryContainerOS() string { return "linux" }
