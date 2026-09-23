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
// gets. It forwards to the pod at the container port. It used to forward at the
// host port and leave the rewrite to the pod's own portmap rule, which is never
// written -- portmap runs nft by PATH and ferry's nft needs its own loader -- so
// a hostPort of 5001 for a containerPort of 5000 arrived at 5001. A line
// without a container port (an older ferry-cri) is still forwarded that way.
//
// The pod is dialled at its own address. This node's vmnet network is its slice
// of the cluster CIDR and the Mac is on it, so there is nothing to translate.
//
// A hostPort below 1024 on a particular hostIP is served from the wildcard
// address and answered only at that one, for the reason a LoadBalancer is: macOS
// lets anyone bind the wildcard below 1024, and only root a particular address.
//
// ferry-cri writes the file; this reads it. The format is one mapping per line:
//
//	<host address or *> <port> <tcp|udp|sctp> <address the Mac can reach the pod at> [<container port>]
//
// An sctp line is said once and not served: macOS has no SCTP sockets.

import (
	"net"
	"net/netip"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/klog/v2"
)

type hostPortMapping struct {
	hostIP        string
	port          int32
	protocol      string
	pod           string
	containerPort int32 // 0: not given, so the pod is dialled at port
}

func (m hostPortMapping) key() string {
	return net.JoinHostPort(m.hostIP, strconv.Itoa(int(m.port))) + "/" + m.protocol
}

// hostPorts keeps one listener per mapping ferry-cri has published.
type hostPorts struct {
	path string

	mu      sync.Mutex
	current map[string]*serviceProxy
	udp     map[string]*udpProxy
	sctp    map[string]bool // already said it cannot be served
}

func newHostPorts(path string) *hostPorts {
	h := &hostPorts{path: path, current: map[string]*serviceProxy{}, udp: map[string]*udpProxy{},
		sctp: map[string]bool{}}
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
		if len(fields) != 4 && len(fields) != 5 {
			continue
		}
		port, err := strconv.Atoi(fields[1])
		if err != nil || port <= 0 || port > 65535 {
			continue
		}
		host := fields[0]
		if host == "*" || host == "0.0.0.0" || host == "::" {
			// Every interface, which is what an unset hostIP means.
			host = ""
		}
		mapping := hostPortMapping{
			hostIP:   host,
			port:     int32(port),
			protocol: fields[2],
			pod:      fields[3],
		}
		if len(fields) == 5 {
			if n, err := strconv.Atoi(fields[4]); err == nil && n > 0 && n <= 65535 {
				mapping.containerPort = int32(n)
			}
		}
		out = append(out, mapping)
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
		wanted[mapping.key()] = mapping
	}

	h.mu.Lock()
	defer h.mu.Unlock()
	for key, mapping := range wanted {
		if mapping.protocol != "sctp" {
			continue
		}
		delete(wanted, key)
		if !h.sctp[key] {
			h.sctp[key] = true
			klog.InfoS("An SCTP hostPort cannot be served on macOS, which has no SCTP sockets; "+
				"the pod still answers at its own address", "listen", key, "pod", mapping.pod)
		}
	}
	for key, proxy := range h.current {
		if _, keep := wanted[key]; !keep {
			proxy.close()
			delete(h.current, key)
			if u, ok := h.udp[key]; ok {
				u.close()
				delete(h.udp, key)
			}
			klog.InfoS("Host port released", "listen", key)
		}
	}
	for key, mapping := range wanted {
		var target backend
		if mapping.containerPort != 0 {
			target = podBackend(net.JoinHostPort(mapping.pod, strconv.Itoa(int(mapping.containerPort))))
		} else {
			target = podBackend(net.JoinHostPort(mapping.pod, strconv.Itoa(int(mapping.port))))
			target.hostPort = true // policy knows it by the container port
		}
		targets := []backend{target}
		if existing, ok := h.current[key]; ok {
			existing.setBackends(targets)
			continue
		}
		protocol := corev1.ProtocolTCP
		if mapping.protocol == "udp" {
			protocol = corev1.ProtocolUDP
		}
		address, only := mapping.hostIP, localAddresses(nil)
		if ip, err := netip.ParseAddr(address); err == nil && mapping.port < 1024 &&
			(ip.Unmap().Is4() || protocol == corev1.ProtocolTCP) {
			address, only = "", localAddresses{ip.Unmap()}
		}
		proxy, err := newServiceProxy("hostPort "+key, address, mapping.port, protocol, only)
		if err != nil {
			// Two pods asking for the same hostPort is the scheduler's problem,
			// not ours, and it is worth saying rather than retrying silently.
			klog.ErrorS(err, "Could not listen for a hostPort", "listen", key)
			continue
		}
		proxy.setBackends(targets)
		if protocol == corev1.ProtocolUDP {
			// A UDP serviceProxy is only a backend list; the datagram listener
			// is separate, and borrows it.
			u, err := newUDPProxy("hostPort "+key, address, mapping.port, proxy, only)
			if err != nil {
				klog.ErrorS(err, "Could not listen for a hostPort", "listen", key, "protocol", "UDP")
				proxy.close()
				continue
			}
			h.udp[key] = u
		}
		h.current[key] = proxy
		klog.InfoS("Host port published", "listen", key, "pod", mapping.pod, "protocol", mapping.protocol)
	}
}
