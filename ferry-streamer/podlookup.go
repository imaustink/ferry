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

type podContainers struct {
	// Names only. The container configuration still comes from CRI; this is
	// purely about knowing when the set is complete.
	InitContainers []string `json:"initContainers"`
	Containers     []string `json:"containers"`
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
		for _, c := range pod.Spec.InitContainers {
			out.InitContainers = append(out.InitContainers, c.Name)
		}
		for _, c := range pod.Spec.Containers {
			out.Containers = append(out.Containers, c.Name)
		}
		json.NewEncoder(w).Encode(out)
	})
}
