//go:build darwin

package prober

// Probes come from the Mac, and the Mac is not on the pod network.
//
// A pod's address -- the one Kubernetes calls the pod IP -- lives on ferry's
// switch, which carries traffic between pods. The kubelet is a macOS process and
// is not on that switch, so probing a pod at its pod IP times out: every HTTP
// and TCP readiness and liveness probe fails, and workloads with probes never
// become Ready. metrics-server is the first thing most people install, and it
// has one.
//
// Each pod also has a vmnet address the Mac can reach, and ferry-cri writes the
// two down side by side. This reads that file so a probe goes somewhere it can
// arrive. Nothing about the pod's identity changes: the cluster still knows it
// by its pod IP, and this is only where the connection is aimed.

import (
	"bufio"
	"os"
	"strings"
	"sync"
	"time"
)

var ferryPodMap struct {
	sync.RWMutex
	byPod   map[string]string
	loaded  time.Time
	path    string
	started bool
}

// ferryReachableAddress returns an address the Mac can connect to for this pod.
// Unknown addresses are returned unchanged, which is what a single-node ferry
// without a cluster network wants anyway.
func ferryReachableAddress(podIP string) string {
	if podIP == "" {
		return podIP
	}
	ferryPodMap.RLock()
	started, host := ferryPodMap.started, ferryPodMap.byPod[podIP]
	ferryPodMap.RUnlock()
	if !started {
		ferryLoadPodMap()
		ferryPodMap.RLock()
		host = ferryPodMap.byPod[podIP]
		ferryPodMap.RUnlock()
	}
	if host != "" {
		return host
	}
	// A pod that appeared since the last read: refresh, but not on every probe.
	if time.Since(ferryPodMapLoadedAt()) > 2*time.Second {
		ferryLoadPodMap()
		ferryPodMap.RLock()
		host = ferryPodMap.byPod[podIP]
		ferryPodMap.RUnlock()
	}
	if host != "" {
		return host
	}
	return podIP
}

func ferryPodMapLoadedAt() time.Time {
	ferryPodMap.RLock()
	defer ferryPodMap.RUnlock()
	return ferryPodMap.loaded
}

func ferryLoadPodMap() {
	path := os.Getenv("FERRY_POD_MAP")
	if path == "" {
		path = "/tmp/ferry-run/cri/podmap"
	}
	next := map[string]string{}
	if file, err := os.Open(path); err == nil {
		scanner := bufio.NewScanner(file)
		for scanner.Scan() {
			fields := strings.Fields(scanner.Text())
			if len(fields) == 2 {
				next[fields[0]] = fields[1]
			}
		}
		file.Close()
	}
	ferryPodMap.Lock()
	ferryPodMap.byPod = next
	ferryPodMap.loaded = time.Now()
	ferryPodMap.path = path
	ferryPodMap.started = true
	ferryPodMap.Unlock()
}
