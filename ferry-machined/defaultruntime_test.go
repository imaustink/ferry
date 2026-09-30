package main

import (
	"context"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
)

func node(name, mode string, taints ...corev1.Taint) *corev1.Node {
	return &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{Name: name, Labels: map[string]string{modeLabel: mode}},
		Spec:       corev1.NodeSpec{Taints: taints},
	}
}

func policyMap(policy string) *corev1.ConfigMap {
	return &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{Name: configName, Namespace: configNamespace},
		Data:       map[string]string{defaultRuntimeKey: policy},
	}
}

func modeTaintOf(t *testing.T, c *controller, name string) string {
	t.Helper()
	n, err := c.kube.CoreV1().Nodes().Get(context.Background(), name, metav1.GetOptions{})
	if err != nil {
		t.Fatal(err)
	}
	got := ""
	for _, taint := range n.Spec.Taints {
		if taint.Key == modeLabel && taint.Effect == corev1.TaintEffectNoSchedule {
			got += taint.Value + ";"
		}
	}
	return got
}

var notReady = corev1.Taint{Key: "node.kubernetes.io/not-ready", Effect: corev1.TaintEffectNoSchedule}

// Each default keeps pods off the other kind of node, and only that kind.
func TestDefaultRuntimeTaintsTheOtherKind(t *testing.T) {
	for _, tc := range []struct {
		policy, mac, machine string
	}{
		{runtimeVM, "", "shared;"},
		{runtimeShared, "vm-per-pod;", ""},
		{"", "", ""},
		{"something-else", "", ""},
	} {
		c := &controller{kube: fake.NewSimpleClientset(
			policyMap(tc.policy), node("mac", modeVMPerPod), node("m0", modeShared))}
		c.reconcileDefaultRuntime(context.Background())
		if got := modeTaintOf(t, c, "mac"); got != tc.mac {
			t.Errorf("policy %q: Mac taint %q, want %q", tc.policy, got, tc.mac)
		}
		if got := modeTaintOf(t, c, "m0"); got != tc.machine {
			t.Errorf("policy %q: machine taint %q, want %q", tc.policy, got, tc.machine)
		}
	}
}

// Changing the default moves the taint rather than adding a second one, and
// leaves every taint that is not ferry's alone.
func TestDefaultRuntimeSwitchesCleanly(t *testing.T) {
	macTaint := corev1.Taint{Key: modeLabel, Value: modeVMPerPod, Effect: corev1.TaintEffectNoSchedule}
	kube := fake.NewSimpleClientset(policyMap(runtimeVM),
		node("mac", modeVMPerPod, macTaint, notReady), node("m0", modeShared))
	c := &controller{kube: kube}
	c.reconcileDefaultRuntime(context.Background())
	if got := modeTaintOf(t, c, "mac"); got != "" {
		t.Errorf("Mac kept the old default's taint: %q", got)
	}
	if got := modeTaintOf(t, c, "m0"); got != "shared;" {
		t.Errorf("machine taint %q, want shared", got)
	}
	n, _ := kube.CoreV1().Nodes().Get(context.Background(), "mac", metav1.GetOptions{})
	if len(n.Spec.Taints) != 1 || n.Spec.Taints[0].Key != notReady.Key {
		t.Errorf("a taint that is not ferry's was touched: %+v", n.Spec.Taints)
	}
	if c.policy != runtimeVM {
		t.Errorf("policy remembered as %q", c.policy)
	}
}

// No ConfigMap is a cluster with no default, which is every cluster before
// this existed: nothing is tainted.
func TestNoConfigMapIsNoDefault(t *testing.T) {
	c := &controller{kube: fake.NewSimpleClientset(node("mac", modeVMPerPod), node("m0", modeShared))}
	c.reconcileDefaultRuntime(context.Background())
	if modeTaintOf(t, c, "mac")+modeTaintOf(t, c, "m0") != "" {
		t.Error("a cluster with no default got a taint")
	}
}

func TestWithModeTaint(t *testing.T) {
	wrong := corev1.Taint{Key: modeLabel, Value: "other", Effect: corev1.TaintEffectNoSchedule}
	got, changed := withModeTaint([]corev1.Taint{wrong, notReady}, modeShared, true)
	if !changed || len(got) != 2 || got[1].Value != modeShared {
		t.Errorf("a wrong value is replaced, not kept beside: %+v", got)
	}
	if _, changed := withModeTaint(got, modeShared, true); changed {
		t.Error("a node already right is left alone")
	}
	// NoExecute under the same key is someone else's decision.
	evict := corev1.Taint{Key: modeLabel, Value: modeShared, Effect: corev1.TaintEffectNoExecute}
	if out, changed := withModeTaint([]corev1.Taint{evict}, modeShared, false); changed || len(out) != 1 {
		t.Errorf("a NoExecute taint was touched: %+v", out)
	}
}

// A machine made while ferry-vm is the default registers already tainted, and
// the taint Karpenter's NodePool asked for is not doubled.
func TestRegistrationTaint(t *testing.T) {
	want := "ferry.dev/mode=shared:NoSchedule"
	if got := withRegistrationTaint(nil, runtimeVM); len(got) != 1 || got[0] != want {
		t.Errorf("got %v", got)
	}
	if got := withRegistrationTaint([]string{want}, runtimeVM); len(got) != 1 {
		t.Errorf("doubled: %v", got)
	}
	if got := withRegistrationTaint(nil, runtimeShared); len(got) != 0 {
		t.Errorf("a ferry-shared default tainted a machine: %v", got)
	}
}
