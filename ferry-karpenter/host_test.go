package main

import (
	"context"
	"testing"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func node(name string, labels map[string]string, memory string) *corev1.Node {
	n := &corev1.Node{ObjectMeta: metav1.ObjectMeta{Name: name, Labels: labels}}
	if memory != "" {
		n.Status.Capacity = corev1.ResourceList{corev1.ResourceMemory: resource.MustParse(memory)}
	}
	return n
}

func macNode(name, host string) *corev1.Node {
	return node(name, map[string]string{hostLabel: host, modeLabel: modeVMPerPod}, "32Gi")
}

func podOn(name, nodeName, memory string, phase corev1.PodPhase) *corev1.Pod {
	p := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "default"},
		Spec: corev1.PodSpec{
			NodeName: nodeName,
			Containers: []corev1.Container{{
				Name: "c",
				Resources: corev1.ResourceRequirements{Requests: corev1.ResourceList{
					corev1.ResourceMemory: resource.MustParse(memory),
				}},
			}},
		},
		Status: corev1.PodStatus{Phase: phase},
	}
	return p
}

func hostProvider(hostNode string, objects ...client.Object) *Provider {
	scheme := runtime.NewScheme()
	_ = corev1.AddToScheme(scheme)
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(objects...).
		// The index Karpenter's operator registers, which host() reads through.
		WithIndex(&corev1.Pod{}, "spec.nodeName", func(o client.Object) []string {
			return []string{o.(*corev1.Pod).Spec.NodeName}
		}).Build()
	return &Provider{nodeClass: &FerryNodeClass{}, kube: c, hostNode: hostNode}
}

// What the Mac's pods hold is theirs: every vm-per-pod node on this Mac, the
// pod VM overhead included, and nothing that has finished, runs on a machine,
// or runs on another Mac.
func TestHostCountsOnlyThisMacsLivePods(t *testing.T) {
	overhead := podOn("vm", "mac", "256Mi", corev1.PodRunning)
	overhead.Spec.Overhead = corev1.ResourceList{corev1.ResourceMemory: resource.MustParse("133Mi")}

	p := hostProvider("mac",
		macNode("mac", "mac"),
		macNode("mac-worker-1", "mac"), // ferry node add: the same RAM
		macNode("other-mac", "other-mac"),
		node("machine-0", map[string]string{hostLabel: "mac", modeLabel: modeShared}, "4Gi"),
		overhead,
		podOn("pending", "mac", "512Mi", corev1.PodPending),
		podOn("beside", "mac-worker-1", "1Gi", corev1.PodRunning),
		podOn("done", "mac", "8Gi", corev1.PodSucceeded),
		podOn("failed", "mac", "8Gi", corev1.PodFailed),
		podOn("in-a-machine", "machine-0", "2Gi", corev1.PodRunning),
		podOn("elsewhere", "other-mac", "4Gi", corev1.PodRunning),
	)
	h, err := p.host(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !h.known || h.capacity != 32<<30 {
		t.Fatalf("host %+v, want a known 32 GiB Mac", h)
	}
	if want := int64((256 + 133 + 512 + 1024) << 20); h.podMemory != want {
		t.Errorf("pods hold %d MiB, want %d", h.podMemory>>20, want>>20)
	}
}

// No Mac node to read is the budget alone, which is what applied before, and
// not an error that stops provisioning.
func TestAnUnknownHostDoesNotBlock(t *testing.T) {
	for name, p := range map[string]*Provider{
		"no name":       hostProvider(""),
		"not yet there": hostProvider("mac"),
		"no capacity":   hostProvider("mac", node("mac", nil, "")),
	} {
		h, err := p.host(context.Background())
		if err != nil || h.known {
			t.Errorf("%s: host %+v, %v; want unknown and no error", name, h, err)
		}
		if !h.fits(shape{}, shape{cpus: 64, memoryGi: 1024}) {
			t.Errorf("%s: an unknown host refused a machine", name)
		}
	}
}

// The case the ledger exists for: a budget with room in it, and a Mac whose
// pods already hold the memory.
func TestTheMacsPodsNarrowTheChoice(t *testing.T) {
	b := bounds{limitCPUs: 8, limitMemoryGi: 16}
	h := host{known: true, capacity: 32 << 30, podMemory: 26 << 30}
	candidates := []shape{{cpus: 2, memoryGi: 2}, {cpus: 4, memoryGi: 8}}

	got, ok := cheapestThatFits(b, h, shape{cpus: 2, memoryGi: 2}, candidates)
	if !ok || got.memoryGi != 2 {
		t.Errorf("with 4 GiB of the Mac left, chose %v (ok=%v); want the 2 GiB shape", got, ok)
	}
	if _, ok := cheapestThatFits(b, h, shape{cpus: 2, memoryGi: 6}, candidates); ok {
		t.Error("a machine was afforded from memory the Mac's pods hold")
	}
}
