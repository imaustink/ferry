package main

// The cluster's default runtime: where a pod lands when it names no
// RuntimeClass.
//
// Kubernetes has no default RuntimeClass. What it has is taints: taint one
// kind of node, give the RuntimeClass that runs there a toleration, and a pod
// that says nothing can only go to the other kind. So a default of ferry-vm
// taints the machines and a default of ferry-shared taints the Macs, and
// manifests/runtimeclasses.yaml gives each class the toleration for its own
// nodes' taint.
//
// Without a default, a Deployment with no selector was split across both
// modes by whatever the scheduler scored -- measured at 5/5 of ten replicas,
// which quietly corrupted three benchmark runs (docs/BENCHMARKING.md).
//
// The policy is read from the cluster, not from a flag. ferry publishes its
// config file into kube-system/ferry-config (see ferry_config_publish), so
// `ferry config set defaultRuntime` changes a running cluster without
// restarting this controller, and `kubectl get cm -n kube-system ferry-config`
// shows what it is acting on. It is applied here, on every tick, rather than
// once by `ferry up`, because nodes arrive after `ferry up` has finished:
// machines, which this controller makes, and Macs that join later.

import (
	"context"
	"log"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

const (
	configNamespace   = "kube-system"
	configName        = "ferry-config"
	defaultRuntimeKey = "defaultRuntime"

	runtimeVM     = "ferry-vm"
	runtimeShared = "ferry-shared"
	modeVMPerPod  = "vm-per-pod"
)

// taintedMode is which kind of node a policy keeps pods off unless they
// tolerate it, or "" for none.
func taintedMode(policy string) string {
	switch policy {
	case runtimeVM:
		return modeShared
	case runtimeShared:
		return modeVMPerPod
	}
	return ""
}

// registrationTaint is the default's taint in the kubelet's own
// --register-with-taints spelling, for a machine that should be born with it.
func registrationTaint(policy string) string {
	if taintedMode(policy) != modeShared {
		return ""
	}
	return modeLabel + "=" + modeShared + ":NoSchedule"
}

// withModeTaint returns taints with ferry's mode taint present, carrying
// value, or absent, and whether that changed anything. Only the
// ferry.dev/mode NoSchedule taint is touched; everything else a node carries
// -- not-ready, Karpenter's own -- is left exactly as it was.
func withModeTaint(taints []corev1.Taint, value string, want bool) ([]corev1.Taint, bool) {
	out := make([]corev1.Taint, 0, len(taints)+1)
	found, changed := false, false
	for _, t := range taints {
		if t.Key != modeLabel || t.Effect != corev1.TaintEffectNoSchedule {
			out = append(out, t)
			continue
		}
		if want && !found && t.Value == value {
			found = true
			out = append(out, t)
			continue
		}
		changed = true
	}
	if want && !found {
		out = append(out, corev1.Taint{Key: modeLabel, Value: value, Effect: corev1.TaintEffectNoSchedule})
		changed = true
	}
	return out, changed
}

// defaultRuntime reads the policy. ok is false when it could not be read,
// which is different from a policy of none: a transient error must not strip
// the taints a default put there.
func (c *controller) defaultRuntime(ctx context.Context) (policy string, ok bool) {
	cm, err := c.kube.CoreV1().ConfigMaps(configNamespace).Get(ctx, configName, metav1.GetOptions{})
	if apierrors.IsNotFound(err) {
		return "", true
	}
	if err != nil {
		log.Printf("default runtime: reading %s/%s: %v", configNamespace, configName, err)
		return "", false
	}
	switch p := cm.Data[defaultRuntimeKey]; p {
	case runtimeVM, runtimeShared:
		return p, true
	default:
		return "", true
	}
}

// reconcileDefaultRuntime makes every labelled node's taint match the policy,
// and remembers the policy for machines created this tick.
func (c *controller) reconcileDefaultRuntime(ctx context.Context) {
	policy, ok := c.defaultRuntime(ctx)
	if !ok {
		return
	}
	if policy != c.policy {
		log.Printf("default runtime: %q", policy)
		c.policy = policy
	}
	nodes, err := c.kube.CoreV1().Nodes().List(ctx, metav1.ListOptions{LabelSelector: modeLabel})
	if err != nil {
		log.Printf("default runtime: listing nodes: %v", err)
		return
	}
	tainted := taintedMode(policy)
	for i := range nodes.Items {
		node := &nodes.Items[i]
		mode := node.Labels[modeLabel]
		taints, changed := withModeTaint(node.Spec.Taints, mode, mode == tainted)
		if !changed {
			continue
		}
		// An update, not a patch replacing the list: the node lifecycle
		// controller and Karpenter add taints of their own, and a conflict on
		// resourceVersion is a retry next tick rather than one of theirs lost.
		node.Spec.Taints = taints
		if _, err := c.kube.CoreV1().Nodes().Update(ctx, node, metav1.UpdateOptions{}); err != nil {
			if !apierrors.IsConflict(err) {
				log.Printf("default runtime: tainting %s: %v", node.Name, err)
			}
			continue
		}
		if mode == tainted {
			log.Printf("default runtime: %s tainted %s=%s:NoSchedule", node.Name, modeLabel, mode)
		} else {
			log.Printf("default runtime: %s untainted", node.Name)
		}
	}
}

// withRegistrationTaint adds the default's taint to what a machine's kubelet
// registers with, once. Karpenter's machines usually carry it already, from
// the NodePool; a Machine written by hand does not.
func withRegistrationTaint(taints []string, policy string) []string {
	t := registrationTaint(policy)
	if t == "" {
		return taints
	}
	for _, have := range taints {
		if have == t {
			return taints
		}
	}
	return append(taints, t)
}
