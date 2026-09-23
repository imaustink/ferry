package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes/fake"
)

func blockVolume(name, image string) *corev1.PersistentVolume {
	return &corev1.PersistentVolume{
		ObjectMeta: metav1.ObjectMeta{Name: name},
		Spec: corev1.PersistentVolumeSpec{PersistentVolumeSource: corev1.PersistentVolumeSource{
			FlexVolume: &corev1.FlexPersistentVolumeSource{Driver: blockDriver,
				Options: map[string]string{"image": image}},
		}},
	}
}

func claim(name, volume string) *corev1.PersistentVolumeClaim {
	return &corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "default"},
		Spec:       corev1.PersistentVolumeClaimSpec{VolumeName: volume},
	}
}

func podWith(name, node, claimName string) *corev1.Pod {
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "default"},
		Spec: corev1.PodSpec{NodeName: node, Volumes: []corev1.Volume{{
			Name: "data", VolumeSource: corev1.VolumeSource{
				PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{ClaimName: claimName}},
		}}},
		Status: corev1.PodStatus{Phase: corev1.PodRunning},
	}
}

func attacherFor(t *testing.T, objects ...any) *attacher {
	t.Helper()
	client := fake.NewSimpleClientset()
	factory := informers.NewSharedInformerFactory(client, 0)
	a := &attacher{
		pods:    factory.Core().V1().Pods().Lister(),
		claims:  factory.Core().V1().PersistentVolumeClaims().Lister(),
		volumes: factory.Core().V1().PersistentVolumes().Lister(),
	}
	for _, o := range objects {
		switch o := o.(type) {
		case *corev1.Pod:
			factory.Core().V1().Pods().Informer().GetStore().Add(o)
		case *corev1.PersistentVolumeClaim:
			factory.Core().V1().PersistentVolumeClaims().Informer().GetStore().Add(o)
		case *corev1.PersistentVolume:
			factory.Core().V1().PersistentVolumes().Informer().GetStore().Add(o)
		}
	}
	return a
}

func listed(t *testing.T, name string) string {
	data, _ := os.ReadFile(filepath.Join(*machinesDir, name+".usb"))
	return strings.TrimSpace(string(data))
}

func TestADiskGoesToOneMachineAtATime(t *testing.T) {
	*machinesDir = t.TempDir()
	machines := map[string]bool{"worker-a": true, "worker-b": true}
	both := []any{
		blockVolume("pv-1", "/v/pvc-1/disk.ext4"), claim("data", "pv-1"),
		podWith("db-b", "worker-b", "data"),
	}
	attacherFor(t, both...).reconcile(machines)
	if got := listed(t, "worker-b"); got != "/v/pvc-1/disk.ext4" {
		t.Fatalf("worker-b lists %q", got)
	}

	// A second pod on another machine wants it too: worker-b keeps it, even
	// though worker-a sorts first.
	attacherFor(t, append(both, podWith("db-a", "worker-a", "data"))...).reconcile(machines)
	if got := listed(t, "worker-a"); got != "" {
		t.Fatalf("worker-a was given a disk worker-b holds: %q", got)
	}
	if got := listed(t, "worker-b"); got != "/v/pvc-1/disk.ext4" {
		t.Fatalf("worker-b lost its disk: %q", got)
	}

	// worker-b's pod goes: the disk moves.
	attacherFor(t, blockVolume("pv-1", "/v/pvc-1/disk.ext4"), claim("data", "pv-1"),
		podWith("db-a", "worker-a", "data")).reconcile(machines)
	if got := listed(t, "worker-b"); got != "" {
		t.Fatalf("worker-b still lists %q", got)
	}
	if got := listed(t, "worker-a"); got != "/v/pvc-1/disk.ext4" {
		t.Fatalf("worker-a lists %q", got)
	}

	// A machine that is gone lets go of its file.
	attacherFor(t).reconcile(map[string]bool{"worker-b": true})
	if _, err := os.Stat(filepath.Join(*machinesDir, "worker-a.usb")); err == nil {
		t.Fatal("a gone machine's .usb file was left behind")
	}
}

func TestAMountedDiskIsNotPulledOut(t *testing.T) {
	*machinesDir = t.TempDir()
	vol := filepath.Join(t.TempDir(), "pvc-1")
	os.MkdirAll(vol, 0o755)
	image := filepath.Join(vol, "disk.ext4")
	machines := map[string]bool{"worker-a": true, "worker-b": true}
	attacherFor(t, blockVolume("pv-1", image), claim("data", "pv-1"),
		podWith("db", "worker-a", "data")).reconcile(machines)
	// The pod is force-deleted while worker-a still has the filesystem mounted.
	os.WriteFile(filepath.Join(vol, ".ferry-mounted"), []byte("worker-a\n"), 0o644)
	attacherFor(t, blockVolume("pv-1", image), claim("data", "pv-1"),
		podWith("db2", "worker-b", "data")).reconcile(machines)
	if got := listed(t, "worker-a"); got != image {
		t.Fatalf("worker-a lost a mounted disk: %q", got)
	}
	if got := listed(t, "worker-b"); got != "" {
		t.Fatalf("worker-b was given a disk mounted elsewhere: %q", got)
	}
	// The kubelet unmounts; the lease goes; the disk moves.
	os.Remove(filepath.Join(vol, ".ferry-mounted"))
	attacherFor(t, blockVolume("pv-1", image), claim("data", "pv-1"),
		podWith("db2", "worker-b", "data")).reconcile(machines)
	if got := listed(t, "worker-b"); got != image {
		t.Fatalf("worker-b lists %q", got)
	}
}

func TestOnlyBlockClaimsAreAttached(t *testing.T) {
	*machinesDir = t.TempDir()
	dir := &corev1.PersistentVolume{ObjectMeta: metav1.ObjectMeta{Name: "pv-dir"},
		Spec: corev1.PersistentVolumeSpec{PersistentVolumeSource: corev1.PersistentVolumeSource{
			HostPath: &corev1.HostPathVolumeSource{Path: "/v/pvc-2"}}}}
	done := podWith("finished", "worker-a", "blk")
	done.Status.Phase = corev1.PodSucceeded
	attacherFor(t, dir, claim("dir", "pv-dir"), podWith("web", "worker-a", "dir"),
		blockVolume("pv-3", "/v/pvc-3/disk.ext4"), claim("blk", "pv-3"), done,
		podWith("mac-pod", "ferry-mac", "blk"),
	).reconcile(map[string]bool{"worker-a": true})
	if got := listed(t, "worker-a"); got != "" {
		t.Fatalf("worker-a lists %q", got)
	}
}
