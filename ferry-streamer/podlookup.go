package main

// Which containers a pod has, and what they run, for ferry-cri.
//
// Virtualization.framework cannot add a disk to a running VM, and a pod's
// images and volumes are disks, while the kubelet creates containers one at a
// time -- create(main), start(main), create(sidecar). A container can join a
// running pod VM only if the VM already has its image. CRI never tells a
// runtime how many containers to expect or what they run, so ferry-cri asks
// here, holds the boot until they have all been created, and attaches every
// image the spec names.

import (
	"context"
	"encoding/json"
	"net/http"

	v1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
)

type podLookup struct {
	client *kubernetes.Clientset
}

func newPodLookup(kubeconfig string) (*podLookup, error) {
	config, err := clientcmd.BuildConfigFromFlags("", kubeconfig)
	if err != nil {
		return nil, err
	}
	client, err := kubernetes.NewForConfig(config)
	if err != nil {
		return nil, err
	}
	return &podLookup{client: client}, nil
}

// The extended resource a pod asks for to be given a socket to the Mac's GPU.
// There is no GPU to pass through on Apple silicon, so this is not nvidia.com/gpu
// with a different vendor -- see docs/GPU.md.
const gpuResource = "ferry.dev/gpu"

type podContainers struct {
	// Names only. The container configuration still comes from CRI; this is
	// purely about knowing when the set is complete.
	InitContainers []string `json:"initContainers"`
	Containers     []string `json:"containers"`
	// Which of them asked for a GPU. CRI has no field for extended resources --
	// ContainerConfig carries CPU, memory and cgroup settings and nothing else --
	// so the runtime cannot see this from the request it is handed. It is
	// reported here because this handler already has the pod spec open.
	GPUContainers []string `json:"gpuContainers"`
	// What the pod is worth relative to other pods, from PriorityClass. The
	// admission plugin resolves priorityClassName into spec.priority, so this is
	// set on every pod -- 0 when nobody said otherwise. It travels with the GPU
	// request because sharing one device is exactly the situation where "this
	// pod matters more" has to mean something.
	Priority int32 `json:"priority"`
	// What the pod asked for, aggregated the way Kubernetes defines a pod's
	// requirements: init containers run one at a time so the largest of them
	// sets a floor, while regular containers run together and so add up.
	//
	// CRI sends resources per container and never for the pod, which is fine
	// for a runtime whose containers share a machine that already exists. Here
	// the machine is created for the pod, and it has to be big enough before
	// the first container starts -- so the aggregate has to come from somewhere,
	// and this handler already has the spec open.
	//
	// Zero means the pod said nothing, and the runtime keeps its default.
	MemoryLimitBytes int64 `json:"memoryLimitBytes"`
	CPULimit         int32 `json:"cpuLimit"`
	// Every subPath the pod's containers mount of each PersistentVolume, keyed
	// by the volume's name, init containers included.
	//
	// A ReadWriteOnce volume is an ext4 image that ferry-cri formats the first
	// time a pod uses it, and a subPath made then can be given the volume
	// root's mode; one made later cannot, because the guest agent's mkdir
	// ignores the mode it is asked for and a non-root container then finds a
	// root-owned 0755 directory it cannot write to. CRI shows a runtime one
	// container's mounts at a time, and a pod with an init container boots
	// with that one alone, so the main container's subPaths would only arrive
	// after the format. The spec has them all at once.
	VolumeSubPaths map[string][]string `json:"volumeSubPaths,omitempty"`
	// Every emptyDir with medium: Memory, by volume name, and its sizeLimit in
	// bytes -- 0 when it set none.
	//
	// The kubelet cannot say so itself: macOS has no tmpfs, so ferry's kubelet
	// makes a memory-backed emptyDir a plain directory, and CRI then shows the
	// runtime a host path like any other emptyDir's. Secrets, ConfigMaps and
	// projected tokens take the same tmpfs path in the kubelet, so tagging it
	// there would catch them too. The spec says exactly which volumes asked.
	MemoryVolumes map[string]int64 `json:"memoryVolumes,omitempty"`
	// Every image the pod's containers run, init containers included, once
	// each. A pod VM attaches each image it runs as a read-only disk and
	// overlays its containers on it, and a disk cannot be added once the VM
	// is running -- so a VM booted for an init container or a native sidecar
	// attaches the images of what comes after it too, when they are pulled.
	Images []string `json:"images,omitempty"`
}

// memoryVolumes maps each emptyDir the pod asked to keep in memory to its
// sizeLimit in bytes, 0 for none. Nil when there are none.
func memoryVolumes(pod *v1.Pod) map[string]int64 {
	var out map[string]int64
	for _, volume := range pod.Spec.Volumes {
		if volume.EmptyDir == nil || volume.EmptyDir.Medium != v1.StorageMediumMemory {
			continue
		}
		if out == nil {
			out = map[string]int64{}
		}
		var size int64
		if volume.EmptyDir.SizeLimit != nil {
			size = volume.EmptyDir.SizeLimit.Value()
		}
		out[volume.Name] = size
	}
	return out
}

// podImages lists the images a pod's containers run, in spec order, once each.
func podImages(pod *v1.Pod) []string {
	var out []string
	seen := map[string]bool{}
	for _, list := range [][]v1.Container{pod.Spec.InitContainers, pod.Spec.Containers} {
		for _, c := range list {
			if c.Image != "" && !seen[c.Image] {
				seen[c.Image] = true
				out = append(out, c.Image)
			}
		}
	}
	return out
}

// volumeSubPaths maps each PersistentVolume the pod mounts to the subPaths its
// containers use of it. A claim that is not bound yet, or cannot be read, is
// left out: the runtime then falls back to the subPaths CRI shows it.
// subPathExpr is left out too -- it expands per container from the downward
// API, which this does not evaluate.
//
// An emptyDir is an ext4 image too, formatted the same way, and is keyed by its
// own name: that is the name of the kubelet's directory for it, which is what
// the runtime calls the volume.
func (p *podLookup) volumeSubPaths(ctx context.Context, pod *v1.Pod) map[string][]string {
	claims := map[string]string{} // pod volume name -> claim name
	emptyDirs := map[string]bool{}
	for _, volume := range pod.Spec.Volumes {
		if volume.PersistentVolumeClaim != nil {
			claims[volume.Name] = volume.PersistentVolumeClaim.ClaimName
		}
		if volume.EmptyDir != nil {
			emptyDirs[volume.Name] = true
		}
	}
	if len(claims) == 0 && len(emptyDirs) == 0 {
		return nil
	}
	subPaths := map[string][]string{} // pod volume name -> subPaths
	out := map[string][]string{}
	all := append(append([]v1.Container{}, pod.Spec.InitContainers...), pod.Spec.Containers...)
	for _, c := range all {
		for _, mount := range c.VolumeMounts {
			if mount.SubPath == "" {
				continue
			}
			if _, ok := claims[mount.Name]; ok {
				subPaths[mount.Name] = append(subPaths[mount.Name], mount.SubPath)
			}
			if emptyDirs[mount.Name] {
				out[mount.Name] = append(out[mount.Name], mount.SubPath)
			}
		}
	}
	for volume, paths := range subPaths {
		claim, err := p.client.CoreV1().PersistentVolumeClaims(pod.Namespace).Get(ctx, claims[volume], metav1.GetOptions{})
		if err != nil || claim.Spec.VolumeName == "" {
			continue
		}
		out[claim.Spec.VolumeName] = append(out[claim.Spec.VolumeName], paths...)
	}
	return out
}

// podResources aggregates what a pod's containers are allowed to use.
//
// Limits rather than requests: a VM sized to requests would let a container
// inside its own limit take memory the machine does not have, which is the
// failure this exists to prevent. A container with no limit contributes
// nothing, so a pod of unlimited containers keeps the runtime default.
func podResources(pod *v1.Pod) (memory int64, cpus int32) {
	for i := range pod.Spec.Containers {
		limits := pod.Spec.Containers[i].Resources.Limits
		memory += limits.Memory().Value()
		cpus += int32(limits.Cpu().Value())
	}
	// Init containers do not overlap with each other or with the rest, so they
	// raise the floor rather than the total.
	for i := range pod.Spec.InitContainers {
		limits := pod.Spec.InitContainers[i].Resources.Limits
		if m := limits.Memory().Value(); m > memory {
			memory = m
		}
		if c := int32(limits.Cpu().Value()); c > cpus {
			cpus = c
		}
	}
	return memory, cpus
}

// wantsGPU reports whether a container asked for the GPU resource. Limits only:
// an extended resource must be requested and limited equally, and the API
// server defaults requests from limits, so limits is the one that is always set.
func wantsGPU(c *v1.Container) bool {
	quantity, ok := c.Resources.Limits[gpuResource]
	return ok && !quantity.IsZero()
}

func servePodLookup(mux *http.ServeMux, pods *podLookup) {
	mux.HandleFunc("/pod", func(w http.ResponseWriter, r *http.Request) {
		if pods == nil {
			http.Error(w, "pod lookup is not configured", http.StatusServiceUnavailable)
			return
		}
		namespace := r.URL.Query().Get("namespace")
		name := r.URL.Query().Get("name")
		if namespace == "" || name == "" {
			http.Error(w, "namespace and name are required", http.StatusBadRequest)
			return
		}
		pod, err := pods.client.CoreV1().Pods(namespace).Get(r.Context(), name, metav1.GetOptions{})
		if err != nil {
			http.Error(w, err.Error(), http.StatusNotFound)
			return
		}
		out := podContainers{}
		if pod.Spec.Priority != nil {
			out.Priority = *pod.Spec.Priority
		}
		out.MemoryLimitBytes, out.CPULimit = podResources(pod)
		out.VolumeSubPaths = pods.volumeSubPaths(r.Context(), pod)
		out.MemoryVolumes = memoryVolumes(pod)
		out.Images = podImages(pod)
		for _, c := range pod.Spec.InitContainers {
			out.InitContainers = append(out.InitContainers, c.Name)
		}
		for i := range pod.Spec.Containers {
			c := &pod.Spec.Containers[i]
			out.Containers = append(out.Containers, c.Name)
			if wantsGPU(c) {
				out.GPUContainers = append(out.GPUContainers, c.Name)
			}
		}
		json.NewEncoder(w).Encode(out)
	})
}
