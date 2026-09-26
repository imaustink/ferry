package main

import (
	"context"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
)

func podOn(name, node string, owner string) *corev1.Pod {
	p := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "default"},
		Spec:       corev1.PodSpec{NodeName: node},
	}
	if owner != "" {
		p.OwnerReferences = []metav1.OwnerReference{{Kind: owner, Name: "x"}}
	}
	return p
}

func spent(t *testing.T, c *controller, name string) int {
	t.Helper()
	n, err := c.kube.CoreV1().Nodes().Get(context.Background(), name, metav1.GetOptions{})
	if err != nil {
		t.Fatal(err)
	}
	count := 0
	for _, taint := range n.Spec.Taints {
		if taint.Key == spentTaint && taint.Effect == corev1.TaintEffectNoSchedule {
			count++
		}
	}
	return count
}

// A macOS VM machine that has had a pod takes no other: the next pod gets a
// fresh VM rather than the one the last pod had root in.
func TestMacOSVMIsSpentByItsPod(t *testing.T) {
	for _, tc := range []struct {
		name string
		pods []*corev1.Pod
		want int
	}{
		{"no pod yet", nil, 0},
		{"a DaemonSet's pod does not spend it", []*corev1.Pod{podOn("ds", "vm-0", "DaemonSet")}, 0},
		{"its pod does", []*corev1.Pod{podOn("job-abc", "vm-0", "Job")}, 1},
	} {
		kube := fake.NewSimpleClientset(node("vm-0", modeMacOSVM))
		for _, p := range tc.pods {
			_, _ = kube.CoreV1().Pods(p.Namespace).Create(context.Background(), p, metav1.CreateOptions{})
		}
		c := &controller{kube: kube}
		n, _ := kube.CoreV1().Nodes().Get(context.Background(), "vm-0", metav1.GetOptions{})
		c.ensureSpent(context.Background(), n)
		n, _ = kube.CoreV1().Nodes().Get(context.Background(), "vm-0", metav1.GetOptions{})
		c.ensureSpent(context.Background(), n) // and only once
		if got := spent(t, c, "vm-0"); got != tc.want {
			t.Errorf("%s: %d spent taints, want %d", tc.name, got, tc.want)
		}
	}
}
