package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"

	corev1 "k8s.io/api/core/v1"
	storagev1 "k8s.io/api/storage/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	corelisters "k8s.io/client-go/listers/core/v1"
	"k8s.io/klog/v2"
)

type provisioner struct {
	client kubernetes.Interface
	node   string
	root   string
	class  string
	claims corelisters.PersistentVolumeClaimLister
}

// ensureClass offers the StorageClass. WaitForFirstConsumer is not a detail: a
// volume here is a directory on one Mac, so the node has to be chosen before the
// volume exists, not after.
func (p *provisioner) ensureClass(ctx context.Context, makeDefault bool) {
	binding := storagev1.VolumeBindingWaitForFirstConsumer
	reclaim := corev1.PersistentVolumeReclaimDelete
	class := &storagev1.StorageClass{
		ObjectMeta: metav1.ObjectMeta{
			Name:        p.class,
			Annotations: map[string]string{},
		},
		Provisioner:       provisionerName,
		VolumeBindingMode: &binding,
		ReclaimPolicy:     &reclaim,
	}
	if makeDefault {
		class.Annotations["storageclass.kubernetes.io/is-default-class"] = "true"
	}
	_, err := p.client.StorageV1().StorageClasses().Create(ctx, class, metav1.CreateOptions{})
	if err != nil && !apierrors.IsAlreadyExists(err) {
		klog.ErrorS(err, "Could not offer the storage class", "class", p.class)
	}
}

// consider provisions for a claim if it is this node's to serve.
func (p *provisioner) consider(ctx context.Context, obj any) {
	claim, ok := obj.(*corev1.PersistentVolumeClaim)
	if !ok || claim.Status.Phase != corev1.ClaimPending || claim.Spec.VolumeName != "" {
		return
	}
	if claim.Spec.StorageClassName == nil || *claim.Spec.StorageClassName != p.class {
		return
	}
	// Late binding means the scheduler names the node. Until it has, there is
	// nothing to do and nowhere to do it.
	if claim.Annotations[selectedNodeAnnotation] != p.node {
		return
	}

	name := "pvc-" + string(claim.UID)
	if _, err := p.client.CoreV1().PersistentVolumes().Get(ctx, name, metav1.GetOptions{}); err == nil {
		return // already made, waiting to bind
	}

	path := filepath.Join(p.root, name)
	if err := os.MkdirAll(path, 0o777); err != nil {
		klog.ErrorS(err, "Could not create the volume directory", "path", path)
		return
	}

	size := claim.Spec.Resources.Requests[corev1.ResourceStorage]
	if size.IsZero() {
		size = resource.MustParse("1Gi")
	}
	modes := claim.Spec.AccessModes
	if len(modes) == 0 {
		modes = []corev1.PersistentVolumeAccessMode{corev1.ReadWriteOnce}
	}
	reclaim := corev1.PersistentVolumeReclaimDelete
	hostPathType := corev1.HostPathDirectoryOrCreate

	volume := &corev1.PersistentVolume{
		ObjectMeta: metav1.ObjectMeta{
			Name: name,
			Annotations: map[string]string{
				"pv.kubernetes.io/provisioned-by": provisionerName,
			},
		},
		Spec: corev1.PersistentVolumeSpec{
			Capacity:                      corev1.ResourceList{corev1.ResourceStorage: size},
			AccessModes:                   modes,
			PersistentVolumeReclaimPolicy: reclaim,
			StorageClassName:              p.class,
			PersistentVolumeSource: corev1.PersistentVolumeSource{
				HostPath: &corev1.HostPathVolumeSource{Path: path, Type: &hostPathType},
			},
			ClaimRef: &corev1.ObjectReference{
				Kind:      "PersistentVolumeClaim",
				Namespace: claim.Namespace,
				Name:      claim.Name,
				UID:       claim.UID,
			},
			// The directory is on this Mac and nowhere else, so say so. A pod
			// that comes back later is sent to the node holding its data.
			NodeAffinity: &corev1.VolumeNodeAffinity{
				Required: &corev1.NodeSelector{
					NodeSelectorTerms: []corev1.NodeSelectorTerm{{
						MatchExpressions: []corev1.NodeSelectorRequirement{{
							Key:      "kubernetes.io/hostname",
							Operator: corev1.NodeSelectorOpIn,
							Values:   []string{p.node},
						}},
					}},
				},
			},
		},
	}

	if _, err := p.client.CoreV1().PersistentVolumes().Create(ctx, volume, metav1.CreateOptions{}); err != nil {
		if !apierrors.IsAlreadyExists(err) {
			klog.ErrorS(err, "Could not create the volume", "claim", claim.Namespace+"/"+claim.Name)
		}
		return
	}
	klog.InfoS("Provisioned", "claim", claim.Namespace+"/"+claim.Name, "path", path, "size", size.String())
}

// reclaim removes the directory once its volume has been released, which is what
// a Delete reclaim policy promises. Without this a laptop quietly fills up.
func (p *provisioner) reclaim(ctx context.Context, obj any) {
	volume, ok := obj.(*corev1.PersistentVolume)
	if !ok || volume.Status.Phase != corev1.VolumeReleased {
		return
	}
	if volume.Annotations["pv.kubernetes.io/provisioned-by"] != provisionerName {
		return
	}
	if volume.Spec.HostPath == nil || !strings.HasPrefix(volume.Spec.HostPath.Path, p.root) {
		return
	}
	if err := os.RemoveAll(volume.Spec.HostPath.Path); err != nil {
		klog.ErrorS(err, "Could not remove the volume directory", "path", volume.Spec.HostPath.Path)
		return
	}
	if err := p.client.CoreV1().PersistentVolumes().Delete(ctx, volume.Name, metav1.DeleteOptions{}); err != nil {
		klog.ErrorS(err, "Could not delete the volume", "volume", volume.Name)
		return
	}
	klog.InfoS("Reclaimed", "volume", volume.Name, "path", volume.Spec.HostPath.Path)
}
