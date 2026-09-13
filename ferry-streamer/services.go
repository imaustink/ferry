package main

// The Service ruleset ferry-cri pushes into pods.
//
// Computed once here, from one set of informers, rather than by a kube-proxy in
// every pod. Pods receive the result and program their own kernel; nothing
// watches the API from inside a pod and nothing is left running there.

import (
	"encoding/json"
	"net/http"
	"sort"
	"strconv"
	"sync"
	"time"

	corev1 "k8s.io/api/core/v1"
	discoveryv1 "k8s.io/api/discovery/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/client-go/informers"
	corelisters "k8s.io/client-go/listers/core/v1"
	discoverylisters "k8s.io/client-go/listers/discovery/v1"
)

type serviceRule struct {
	Name      string   `json:"name"`
	ClusterIP string   `json:"clusterIP"`
	Port      uint16   `json:"port"`
	Protocol  string   `json:"protocol"`
	Endpoints []string `json:"endpoints"`
}

type serviceWatch struct {
	services corelisters.ServiceLister
	slices   discoverylisters.EndpointSliceLister
	mu       sync.RWMutex
	ready    bool
}

func newServiceWatch(pods *podLookup, stop <-chan struct{}) *serviceWatch {
	if pods == nil {
		return nil
	}
	factory := informers.NewSharedInformerFactory(pods.client, 5*time.Minute)
	watch := &serviceWatch{
		services: factory.Core().V1().Services().Lister(),
		slices:   factory.Discovery().V1().EndpointSlices().Lister(),
	}
	factory.Start(stop)
	go func() {
		factory.WaitForCacheSync(stop)
		watch.mu.Lock()
		watch.ready = true
		watch.mu.Unlock()
	}()
	return watch
}

// ruleset is deterministic: pods compare what they are given against what they
// applied, so an unstable order would cause needless reprogramming.
func (w *serviceWatch) ruleset() ([]serviceRule, error) {
	services, err := w.services.List(labels.Everything())
	if err != nil {
		return nil, err
	}
	slices, err := w.slices.List(labels.Everything())
	if err != nil {
		return nil, err
	}

	type portKey struct{ service, port string }
	endpoints := map[portKey][]string{}
	for _, slice := range slices {
		name := slice.Labels[discoveryv1.LabelServiceName]
		if name == "" {
			continue
		}
		service := slice.Namespace + "/" + name
		for _, port := range slice.Ports {
			if port.Port == nil {
				continue
			}
			portName := ""
			if port.Name != nil {
				portName = *port.Name
			}
			for _, endpoint := range slice.Endpoints {
				if endpoint.Conditions.Ready != nil && !*endpoint.Conditions.Ready {
					continue
				}
				for _, address := range endpoint.Addresses {
					key := portKey{service, portName}
					endpoints[key] = append(endpoints[key],
						address+":"+strconv.Itoa(int(*port.Port)))
				}
			}
		}
	}

	var rules []serviceRule
	for _, service := range services {
		clusterIP := service.Spec.ClusterIP
		if clusterIP == "" || clusterIP == corev1.ClusterIPNone {
			continue // headless: DNS already resolves to pod IPs, which route
		}
		name := service.Namespace + "/" + service.Name
		for _, port := range service.Spec.Ports {
			if port.Protocol != "" && port.Protocol != corev1.ProtocolTCP {
				continue
			}
			backends := append([]string(nil), endpoints[portKey{name, port.Name}]...)
			sort.Strings(backends)
			rules = append(rules, serviceRule{
				Name:      name,
				ClusterIP: clusterIP,
				Port:      uint16(port.Port),
				Protocol:  "TCP",
				Endpoints: backends,
			})
		}
	}
	sort.Slice(rules, func(i, j int) bool {
		if rules[i].Name != rules[j].Name {
			return rules[i].Name < rules[j].Name
		}
		return rules[i].Port < rules[j].Port
	})
	return rules, nil
}

func serveServices(mux *http.ServeMux, watch *serviceWatch) {
	mux.HandleFunc("/services", func(w http.ResponseWriter, r *http.Request) {
		if watch == nil {
			http.Error(w, "service watch is not configured", http.StatusServiceUnavailable)
			return
		}
		watch.mu.RLock()
		ready := watch.ready
		watch.mu.RUnlock()
		if !ready {
			http.Error(w, "service cache is still syncing", http.StatusServiceUnavailable)
			return
		}
		rules, err := watch.ruleset()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		if rules == nil {
			rules = []serviceRule{}
		}
		json.NewEncoder(w).Encode(rules)
	})
}
