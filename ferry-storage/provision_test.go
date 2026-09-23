package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes/fake"
)

// claimOn is a pending claim the scheduler has placed on node.
func claimOn(class, node string, mode corev1.PersistentVolumeAccessMode) *corev1.PersistentVolumeClaim {
	return &corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{
			Name: "data", Namespace: "default", UID: types.UID("1b4e28ba-2fa1-11d2-883f-0016d3cca427"),
			Annotations: map[string]string{selectedNodeAnnotation: node},
		},
		Spec: corev1.PersistentVolumeClaimSpec{
			StorageClassName: &class,
			AccessModes:      []corev1.PersistentVolumeAccessMode{mode},
		},
		Status: corev1.PersistentVolumeClaimStatus{Phase: corev1.ClaimPending},
	}
}

func provision(t *testing.T, claim *corev1.PersistentVolumeClaim) (*corev1.PersistentVolume, string) {
	t.Helper()
	machine := &corev1.Node{ObjectMeta: metav1.ObjectMeta{Name: "worker-0",
		Labels: map[string]string{hostLabel: "mac", "ferry.dev/mode": "shared"}}}
	root := t.TempDir()
	client := fake.NewSimpleClientset(machine)
	p := &provisioner{client: client, node: "mac", root: root, class: "ferry-local", blockClass: "ferry-local-block"}
	p.consider(context.Background(), claim)
	pv, err := client.CoreV1().PersistentVolumes().Get(context.Background(), "pvc-"+string(claim.UID), metav1.GetOptions{})
	if err != nil {
		t.Fatalf("no volume: %v", err)
	}
	return pv, root
}

func TestBlockClassOnAMachineIsADisk(t *testing.T) {
	pv, root := provision(t, claimOn("ferry-local-block", "worker-0", corev1.ReadWriteOnce))
	flex := pv.Spec.FlexVolume
	if flex == nil || flex.Driver != blockDriver {
		t.Fatalf("source = %+v, want a %s FlexVolume", pv.Spec.PersistentVolumeSource, blockDriver)
	}
	image := filepath.Join(root, "pvc-1b4e28ba-2fa1-11d2-883f-0016d3cca427", imageName)
	if flex.Options["image"] != image {
		t.Errorf("image %q, want %q", flex.Options["image"], image)
	}
	if flex.Options["label"] != "1b4e28ba2fa111d2" {
		t.Errorf("label %q", flex.Options["label"])
	}
	if st, err := os.Stat(image); err != nil || st.Size() == 0 {
		t.Errorf("no sparse image made: %v", err)
	}
	// Any machine on this Mac, and not the Mac's own node.
	terms := pv.Spec.NodeAffinity.Required.NodeSelectorTerms[0].MatchExpressions
	if len(terms) != 2 || terms[0].Key != hostLabel || terms[1].Key != "ferry.dev/mode" || terms[1].Values[0] != "shared" {
		t.Errorf("affinity %+v", terms)
	}
	if pv.Spec.StorageClassName != "ferry-local-block" {
		t.Errorf("class %q", pv.Spec.StorageClassName)
	}
}

func TestDefaultClassOnAMachineStaysADirectory(t *testing.T) {
	pv, _ := provision(t, claimOn("ferry-local", "worker-0", corev1.ReadWriteOnce))
	if pv.Spec.HostPath == nil || pv.Spec.FlexVolume != nil {
		t.Fatalf("source = %+v, want the shared directory", pv.Spec.PersistentVolumeSource)
	}
}

func TestBlockClassManyWritersStaysADirectory(t *testing.T) {
	pv, _ := provision(t, claimOn("ferry-local-block", "worker-0", corev1.ReadWriteMany))
	if pv.Spec.HostPath == nil {
		t.Fatalf("source = %+v, want the shared directory", pv.Spec.PersistentVolumeSource)
	}
}

func TestBlockClassOnTheMacIsTheMacsDisk(t *testing.T) {
	pv, root := provision(t, claimOn("ferry-local-block", "mac", corev1.ReadWriteOnce))
	if pv.Spec.HostPath == nil {
		t.Fatalf("source = %+v, want hostPath for ferry-cri", pv.Spec.PersistentVolumeSource)
	}
	if _, err := os.Stat(filepath.Join(root, "pvc-1b4e28ba-2fa1-11d2-883f-0016d3cca427", imageName)); err != nil {
		t.Errorf("no image for ferry-cri to attach: %v", err)
	}
}
