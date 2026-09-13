package main

// hostPort, from the Mac's side.
//
// A hostPort means "reach this container at the node's own address". On Linux
// the CNI portmap plugin writes that rule into the node's kernel, because the
// node and the pod share one. Here they do not: portmap runs inside the pod's
// own kernel, which makes the mapping real on the pod's addresses, and the node
// is a Mac with no netfilter at all.
//
// So the last hop is a listener, the same shape as the one a NodePort already
// gets. It forwards to the pod at the *same* port rather than the container
// port, because the pod's own portmap rule is what rewrites it -- the chain
// stays intact instead of being short-circuited here.
//
// ferry-cri writes the file; this reads it. The format is one mapping per line:
//
//	<host address or *> <port> <tcp|udp> <address the Mac can reach the pod at>

import (
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"k8s.io/klog/v2"
)

type hostPortMapping struct {
	hostIP   string
	port     int32
	protocol string
	pod      string
}

func (m hostPortMapping) key() string {
	return net.JoinHostPort(m.hostIP, strconv.Itoa(int(m.port))) + "/" + m.protocol
}

// hostPorts keeps one listener per mapping ferry-cri has published.
type hostPorts struct {
	path string

	mu      sync.Mutex
	current map[string]*serviceProxy
}

func newHostPorts(path string) *hostPorts {
	h := &hostPorts{path: path, current: map[string]*serviceProxy{}}
	if path == "" {
		return h
	}
	h.reload()
	go func() {
		for range time.Tick(2 * time.Second) {
			h.reload()
		}
	}()
	return h
}

func parseHostPorts(data []byte) []hostPortMapping {
	var out []hostPortMapping
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) != 4 {
			continue
		}
		port, err := strconv.Atoi(fields[1])
		if err != nil || port <= 0 || port > 65535 {
			continue
		}
		host := fields[0]
		if host == "*" {
			// Every interface, which is what an unset hostIP means.
			host = ""
		}
		out = append(out, hostPortMapping{
			hostIP:   host,
			port:     int32(port),
			protocol: fields[2],
			pod:      fields[3],
		})
	}
	return out
}

func (h *hostPorts) reload() {
	data, err := os.ReadFile(h.path)
	if err != nil {
		return
	}
	wanted := map[string]hostPortMapping{}
	for _, mapping := range parseHostPorts(data) {
		if mapping.protocol != "tcp" {
			// Only TCP for now: the forwarder is a stream proxy. A UDP hostPort
			// still works on the pod's own address, where portmap put it.
			klog.V(2).InfoS("Ignoring a non-TCP hostPort", "port", mapping.port, "protocol", mapping.protocol)
			continue
		}
		wanted[mapping.key()] = mapping
	}

	h.mu.Lock()
	defer h.mu.Unlock()
	for key, proxy := range h.current {
		if _, keep := wanted[key]; !keep {
			proxy.close()
			delete(h.current, key)
			klog.InfoS("Host port released", "listen", key)
		}
	}
	for key, mapping := range wanted {
		target := []backend{{address: net.JoinHostPort(mapping.pod, strconv.Itoa(int(mapping.port)))}}
		if existing, ok := h.current[key]; ok {
			existing.setBackends(target)
			continue
		}
		proxy, err := newServiceProxy("hostPort "+key, mapping.hostIP, mapping.port)
		if err != nil {
			// Two pods asking for the same hostPort is the scheduler's problem,
			// not ours, and it is worth saying rather than retrying silently.
			klog.ErrorS(err, "Could not listen for a hostPort", "listen", key)
			continue
		}
		proxy.setBackends(target)
		h.current[key] = proxy
		klog.InfoS("Host port published", "listen", key, "pod", mapping.pod)
	}
}
