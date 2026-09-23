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
	// The class whose single-writer claims are disks on machines too, not
	// only on the Mac's node. Empty when this Mac's machines cannot take a
	// disk after boot -- a kernel without usb-storage. See blockOnMachine.
	blockClass string
	claims     corelisters.PersistentVolumeClaimLister
}

// ensureClass offers the StorageClasses. WaitForFirstConsumer is not a detail: a
// volume here is a directory on one Mac, so the node has to be chosen before the
// volume exists, not after.
func (p *provisioner) ensureClass(ctx context.Context, makeDefault bool) {
	binding := storagev1.VolumeBindingWaitForFirstConsumer
	reclaim := corev1.PersistentVolumeReclaimDelete
	for _, name := range []string{p.class, p.blockClass} {
		if name == "" {
			continue
		}
		class := &storagev1.StorageClass{
			ObjectMeta: metav1.ObjectMeta{
				Name:        name,
				Annotations: map[string]string{},
			},
			Provisioner:       provisionerName,
			VolumeBindingMode: &binding,
			ReclaimPolicy:     &reclaim,
		}
		if makeDefault && name == p.class {
			class.Annotations["storageclass.kubernetes.io/is-default-class"] = "true"
		}
		_, err := p.client.StorageV1().StorageClasses().Create(ctx, class, metav1.CreateOptions{})
		if err != nil && !apierrors.IsAlreadyExists(err) {
			klog.ErrorS(err, "Could not offer the storage class", "class", name)
		}
	}
}

// The FlexVolume driver in the node image that mounts a USB-attached claim.
const blockDriver = "ferry.dev/block"

// diskLabel is the ext4 label a claim's disk is found by inside a machine: the
// claim's UID without dashes, cut to the sixteen bytes a label holds.
// ferry-node writes the same value into the filesystem before attaching it
// (VolumeDisk.label), from the directory name this makes.
func diskLabel(uid string) string {
	s := strings.ReplaceAll(uid, "-", "")
	if len(s) > 16 {
		s = s[:16]
	}
	return s
}

// isMachine reports whether a node is a mode 2 machine: labelled so by
// ferry-machined, or -- in the moment before that label lands -- carrying the
// provider ID it sets.
func isMachine(node *corev1.Node) bool {
	return node.Labels["ferry.dev/mode"] == "shared" || strings.HasPrefix(node.Spec.ProviderID, "ferry://")
}

// consider provisions for a claim if it is this node's to serve.
func (p *provisioner) consider(ctx context.Context, obj any) {
	claim, ok := obj.(*corev1.PersistentVolumeClaim)
	if !ok || claim.Status.Phase != corev1.ClaimPending || claim.Spec.VolumeName != "" {
		return
	}
	if claim.Spec.StorageClassName == nil {
		return
	}
	className := *claim.Spec.StorageClassName
	if className != p.class && (p.blockClass == "" || className != p.blockClass) {
		return
	}
	// Late binding means the scheduler names the node. Until it has, there is
	// nothing to do and nowhere to do it.
	//
	// That node is this Mac's, or one of the machines this Mac runs. The second
	// used to be ignored: every claim a mode 2 pod made waited for a
	// provisioner that had decided it was someone else's, and the pod stayed
	// Pending with no event to say why. A machine mounts this Mac's volumes
	// directory at the same path (ferry-node shares it at boot), so a volume
	// for one is a directory here like any other. So is a volume for a node
	// added with `ferry node add`, which was ignored the same way: its kubelet
	// is on this Mac, and ferry.dev/host names this Mac for it too.
	selected := claim.Annotations[selectedNodeAnnotation]
	if selected == "" {
		return
	}
	elsewhere, machine := false, false
	if selected != p.node {
		node, err := p.client.CoreV1().Nodes().Get(ctx, selected, metav1.GetOptions{})
		if err != nil || node.Labels[hostLabel] != p.node {
			return
		}
		elsewhere, machine = true, isMachine(node)
	}

	name := "pvc-" + string(claim.UID)
	if _, err := p.client.CoreV1().PersistentVolumes().Get(ctx, name, metav1.GetOptions{}); err == nil {
		return // already made, waiting to bind
	}

	size := claim.Spec.Resources.Requests[corev1.ResourceStorage]
	if size.IsZero() {
		size = resource.MustParse("1Gi")
	}
	modes := claim.Spec.AccessModes
	if len(modes) == 0 {
		modes = []corev1.PersistentVolumeAccessMode{corev1.ReadWriteOnce}
	}

	path := filepath.Join(p.root, name)
	if err := os.MkdirAll(path, 0o777); err != nil {
		klog.ErrorS(err, "Could not create the volume directory", "path", path)
		return
	}
	// A disk image only for a pod on the Mac's own node, where ferry-cri
	// attaches it to the pod's VM and the volume is pinned to that node. A
	// machine cannot attach one after it has booted, so a volume anywhere else
	// is the directory, shared, with the chown limit that comes with virtiofs.
	//
	// Except in the block class, where a machine can: the image is attached to
	// the running machine over USB when a pod using it is scheduled there, and
	// mounted by the node image's volume driver. See blockOnMachine.
	block := singleWriter(modes) && !elsewhere
	onMachine := className == p.blockClass && singleWriter(modes) && machine
	if block || onMachine {
		if err := makeImage(filepath.Join(path, imageName), size.Value()); err != nil {
			klog.ErrorS(err, "Could not create the volume's disk image", "path", path)
			return
		}
	}
	reclaim := corev1.PersistentVolumeReclaimDelete
	hostPathType := corev1.HostPathDirectoryOrCreate
	source := corev1.PersistentVolumeSource{
		HostPath: &corev1.HostPathVolumeSource{Path: path, Type: &hostPathType},
	}
	affinity := p.affinity(block)
	if onMachine {
		source, affinity = p.blockOnMachine(path, string(claim.UID))
	}

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
			StorageClassName:              className,
			PersistentVolumeSource:        source,
			ClaimRef: &corev1.ObjectReference{
				Kind:      "PersistentVolumeClaim",
				Namespace: claim.Namespace,
				Name:      claim.Name,
				UID:       claim.UID,
			},
			NodeAffinity: affinity,
		},
	}

	if _, err := p.client.CoreV1().PersistentVolumes().Create(ctx, volume, metav1.CreateOptions{}); err != nil {
		if !apierrors.IsAlreadyExists(err) {
			klog.ErrorS(err, "Could not create the volume", "claim", claim.Namespace+"/"+claim.Name)
		}
		return
	}
	klog.InfoS("Provisioned", "claim", claim.Namespace+"/"+claim.Name, "path", path,
		"size", size.String(), "node", selected, "block", block, "machineDisk", onMachine)
}

// blockOnMachine is a single-writer claim of the block class on a machine: a
// disk image the machine takes over USB after it has booted, rather than a
// directory in the share it mounted at boot, so chown works on it.
//
// The volume is a FlexVolume because something in the machine has to find the
// disk and mount it before the kubelet hands the directory to a pod, and the
// FlexVolume driver in the node image is the smallest thing the kubelet will
// call for that. Attaching is not its job: ferry-machined sees the pod
// scheduled and lists the image in the machine's .usb file, and ferry-node
// attaches it -- the Mac holds the disk, so the Mac decides where it goes, one
// machine at a time.
//
// Pinned to this Mac's machines, any of them: the image stays on the Mac, so a
// pod that comes back on a replacement machine finds its data there. Not to the
// Mac's own node, where the same claim would need a hostPath instead.
func (p *provisioner) blockOnMachine(path, uid string) (corev1.PersistentVolumeSource, *corev1.VolumeNodeAffinity) {
	source := corev1.PersistentVolumeSource{
		FlexVolume: &corev1.FlexPersistentVolumeSource{
			Driver: blockDriver,
			FSType: "ext4",
			Options: map[string]string{
				"image": filepath.Join(path, imageName),
				"label": diskLabel(uid),
			},
		},
	}
	affinity := &corev1.VolumeNodeAffinity{
		Required: &corev1.NodeSelector{
			NodeSelectorTerms: []corev1.NodeSelectorTerm{{
				MatchExpressions: []corev1.NodeSelectorRequirement{
					{Key: hostLabel, Operator: corev1.NodeSelectorOpIn, Values: []string{p.node}},
					{Key: "ferry.dev/mode", Operator: corev1.NodeSelectorOpIn, Values: []string{"shared"}},
				},
			}},
		},
	}
	return source, affinity
}

// Which nodes can reach a volume's data.
//
// A disk image only ever attaches to a pod VM on the Mac, so it is pinned to
// the Mac's node. A directory is the same directory on the Mac and in every
// machine the Mac runs -- they all mount one volumes directory -- so it is
// pinned to ferry.dev/host instead, which the Mac and its machines all carry,
// and a pod can come back on any of them. Either way it is this Mac and
// nowhere else: a pod that comes back later is sent where its data is.
func (p *provisioner) affinity(block bool) *corev1.VolumeNodeAffinity {
	requirement := corev1.NodeSelectorRequirement{
		Key: hostLabel, Operator: corev1.NodeSelectorOpIn, Values: []string{p.node},
	}
	if block {
		requirement.Key = "kubernetes.io/hostname"
	}
	return &corev1.VolumeNodeAffinity{
		Required: &corev1.NodeSelector{
			NodeSelectorTerms: []corev1.NodeSelectorTerm{{
				MatchExpressions: []corev1.NodeSelectorRequirement{requirement},
			}},
		},
	}
}

// Set by `ferry up` on the Mac's node and by ferry-machined on each machine,
// naming the Mac whose volumes directory that node can see.
const hostLabel = "ferry.dev/host"

// The disk image a single-writer volume keeps its filesystem in. ferry-cri
// looks for exactly this name inside a volume directory, so it is part of the
// contract between the two and not a detail of either.
const imageName = "disk.ext4"

// singleWriter reports whether a claim can only ever be used by one pod at a
// time, which is what lets its volume be a block device instead of a share.
//
// A share is served by Virtualization.framework's virtiofs server, which runs
// as the Mac user and so refuses every chown -- an init container that chowns
// its data directory, or postgres insisting its directory be its own and 0700,
// fails with EPERM even as root. An ext4 filesystem inside the pod's own
// kernel has real ownership. But one filesystem can only be mounted by one
// kernel at a time, and every pod here is its own kernel, so only a claim that
// promises a single writer can have one. ReadWriteMany and ReadOnlyMany stay
// shared directories, and chown on them is still unsupported.
func singleWriter(modes []corev1.PersistentVolumeAccessMode) bool {
	for _, mode := range modes {
		if mode != corev1.ReadWriteOnce && mode != corev1.ReadWriteOncePod {
			return false
		}
	}
	return len(modes) > 0
}

// makeImage creates the volume's disk image at the claim's size. It is sparse,
// so it costs what is written to it rather than what the claim asked for, and
// it is left unformatted: ferry-cri formats it the first time a pod mounts it,
// with the same ext4 writer it builds root filesystems with -- there is no
// mkfs on a Mac to do it here. An image left over from an attempt that failed
// before its PersistentVolume was made is kept as it is.
func makeImage(path string, size int64) error {
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE|os.O_EXCL, 0o600)
	if os.IsExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if err := f.Truncate(size); err != nil {
		f.Close()
		os.Remove(path)
		return err
	}
	return f.Close()
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
	var dir string
	switch {
	case volume.Spec.HostPath != nil:
		dir = volume.Spec.HostPath.Path
	case volume.Spec.FlexVolume != nil && volume.Spec.FlexVolume.Driver == blockDriver:
		dir = filepath.Dir(volume.Spec.FlexVolume.Options["image"])
	}
	if dir == "" || !strings.HasPrefix(dir, p.root+string(filepath.Separator)) {
		return
	}
	if err := os.RemoveAll(dir); err != nil {
		klog.ErrorS(err, "Could not remove the volume directory", "path", dir)
		return
	}
	if err := p.client.CoreV1().PersistentVolumes().Delete(ctx, volume.Name, metav1.DeleteOptions{}); err != nil {
		klog.ErrorS(err, "Could not delete the volume", "volume", volume.Name)
		return
	}
	klog.InfoS("Reclaimed", "volume", volume.Name, "path", dir)
}
