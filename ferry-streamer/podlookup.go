package main

// Which containers a pod has, for ferry-cri.
//
// Virtualization.framework cannot add a container to a running VM, and the
// kubelet creates containers one at a time -- create(main), start(main),
// create(sidecar) -- so by the time a sidecar arrives the VM has already
// booted. CRI never tells a runtime how many containers to expect, so ferry-cri
// asks here and holds the boot until they have all been created.

import (
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
