//go:build darwin

package lifecycle

// Pod admission asks the same question node labelling does: what OS do this
// node's containers run?
//
// The admission handler rewrites the node's kubernetes.io/os label to the
// kubelet's own GOOS before testing a pod's selector against it, so on ferry a
// pod asking for linux was rejected by the node it had just been scheduled to --
// the API said linux, the scheduler agreed, and the kubelet overruled both.
//
// ferry's containers run on Linux, each in its own virtual machine, so this
// answers linux for the same reason the node label does.
func ferryContainerOS() string { return "linux" }
