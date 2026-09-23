package main

import (
	"context"
	"reflect"
	"testing"

	v1 "k8s.io/api/core/v1"
)

// The emptyDir half of volumeSubPaths: keyed by the pod volume's own name,
// which is the name of the kubelet's directory and so the name ferry-cri gives
// the volume. None of these cases reach the API server -- a claim is only
// looked up when one of its mounts has a subPath -- so the lookup needs no
// client.
func TestVolumeSubPathsEmptyDir(t *testing.T) {
	mount := func(name, subPath string) v1.VolumeMount {
		return v1.VolumeMount{Name: name, MountPath: "/" + name + "/" + subPath, SubPath: subPath}
	}
	emptyDir := func(name string) v1.Volume {
		return v1.Volume{Name: name, VolumeSource: v1.VolumeSource{EmptyDir: &v1.EmptyDirVolumeSource{}}}
	}
	claim := func(name string) v1.Volume {
		return v1.Volume{Name: name, VolumeSource: v1.VolumeSource{
			PersistentVolumeClaim: &v1.PersistentVolumeClaimVolumeSource{ClaimName: name}}}
	}
	configMap := func(name string) v1.Volume {
		return v1.Volume{Name: name, VolumeSource: v1.VolumeSource{
			ConfigMap: &v1.ConfigMapVolumeSource{LocalObjectReference: v1.LocalObjectReference{Name: name}}}}
	}

	cases := []struct {
		name  string
		spec  v1.PodSpec
		want  map[string][]string
		isNil bool
	}{
		{
			name:  "no emptyDir or claim",
			spec:  v1.PodSpec{Volumes: []v1.Volume{configMap("cfg")}, Containers: []v1.Container{{VolumeMounts: []v1.VolumeMount{mount("cfg", "a")}}}},
			isNil: true,
		},
		{
			name: "init and main subPaths, in spec order",
			spec: v1.PodSpec{
				Volumes:        []v1.Volume{emptyDir("scratch")},
				InitContainers: []v1.Container{{VolumeMounts: []v1.VolumeMount{mount("scratch", "init")}}},
				Containers:     []v1.Container{{VolumeMounts: []v1.VolumeMount{mount("scratch", "one"), mount("scratch", "two")}}},
			},
			want: map[string][]string{"scratch": {"init", "one", "two"}},
		},
		{
			name: "whole-volume mounts are skipped",
			spec: v1.PodSpec{
				Volumes:    []v1.Volume{emptyDir("scratch")},
				Containers: []v1.Container{{VolumeMounts: []v1.VolumeMount{mount("scratch", "")}}},
			},
			want: map[string][]string{},
		},
		{
			name: "mixed with a claim and a configMap",
			spec: v1.PodSpec{
				Volumes: []v1.Volume{emptyDir("snapshots"), claim("data"), configMap("cfg")},
				Containers: []v1.Container{{VolumeMounts: []v1.VolumeMount{
					mount("snapshots", "s"), mount("data", ""), mount("cfg", "c"),
				}}},
			},
			want: map[string][]string{"snapshots": {"s"}},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := (&podLookup{}).volumeSubPaths(context.Background(), &v1.Pod{Spec: c.spec})
			if c.isNil {
				if got != nil {
					t.Fatalf("got %v, want nil", got)
				}
				return
			}
			if !reflect.DeepEqual(got, c.want) {
				t.Fatalf("got %v, want %v", got, c.want)
			}
		})
	}
}

// Init containers first, then the rest, each image once.
func TestPodImages(t *testing.T) {
	pod := &v1.Pod{Spec: v1.PodSpec{
		InitContainers: []v1.Container{{Name: "migrate", Image: "app:1"}, {Name: "proxy", Image: "envoy:1"}},
		Containers:     []v1.Container{{Name: "app", Image: "app:1"}, {Name: "log", Image: "busybox"}, {Name: "blank"}},
	}}
	want := []string{"app:1", "envoy:1", "busybox"}
	if got := podImages(pod); !reflect.DeepEqual(got, want) {
		t.Fatalf("podImages = %v, want %v", got, want)
	}
	if got := podImages(&v1.Pod{}); got != nil {
		t.Fatalf("podImages of an empty pod = %v, want nil", got)
	}
}
