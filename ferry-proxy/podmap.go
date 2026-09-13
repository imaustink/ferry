package main

// Turning a pod IP into something the Mac can dial.
//
// Once ferry has a cluster network, a pod's address -- the one Kubernetes calls
// the pod IP and the one EndpointSlices carry -- lives on ferry's switch. That
// switch carries traffic between pods, and the Mac is not on it. So the host
// side of a Service cannot dial an endpoint by the address the cluster knows it
// by, even for a pod on this very Mac.
//
// ferry-cri knows both addresses and writes them down. This reads that file.
// A pod that has no second address, because there is no cluster network, is
// absent from the map and dialled as-is.

import (
	"os"
	"strings"
	"sync"
	"time"

	"k8s.io/klog/v2"
)

type podMap struct {
	mu    sync.RWMutex
	byPod map[string]string
	path  string
}

func newPodMap(path string) *podMap {
	m := &podMap{byPod: map[string]string{}, path: path}
	if path == "" {
		return m
	}
	m.reload()
	go func() {
		for range time.Tick(2 * time.Second) {
			m.reload()
		}
	}()
	return m
}

func (m *podMap) reload() {
	data, err := os.ReadFile(m.path)
	if err != nil {
		return
	}
	next := map[string]string{}
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 2 {
			next[fields[0]] = fields[1]
		}
	}
	m.mu.Lock()
	changed := len(next) != len(m.byPod)
	m.byPod = next
	m.mu.Unlock()
	if changed {
		klog.V(2).InfoS("Pod addresses reloaded", "count", len(next))
	}
}

// dialable returns the address the Mac can reach this pod at.
func (m *podMap) dialable(podIP string) string {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if host, ok := m.byPod[podIP]; ok {
		return host
	}
	return podIP
}
