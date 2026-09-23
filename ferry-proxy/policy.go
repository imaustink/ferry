package main

// NetworkPolicy, at the edge.
//
// A pod enforces its own ingress policy, in its own kernel, and exempts its own
// node: that is where the kubelet's probes come from, and a pod that drops its
// probes is restarted rather than isolated. But this process dials pods from
// that same node address, on behalf of every NodePort, LoadBalancer and
// hostPort client, so to the pod each of those connections looks like the
// kubelet. The client's real address never reaches it.
//
// It does reach here. So the same rules are checked here, against the address
// the connection actually came from, before a pod is dialled. ferry-netpol
// resolves them once for both places (ferry-netpol/compile.go), which is what
// keeps the edge and the pod from disagreeing about what a policy means.
//
// The check is one map lookup per connection for a pod no policy isolates,
// against a snapshot swapped in atomically when policy changes; nothing here
// takes a lock on the connection path.
//
// A connection this Mac forwards to another node's port is not checked here --
// the node that has the pod checks it, and sees this Mac as the client. That is
// what an externalTrafficPolicy of Cluster means on any cluster: the source is
// rewritten on the way through, and a policy there sees the node.

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"k8s.io/klog/v2"
)

// The document ferry-netpol serves at /edge.
type edgeDocument struct {
	Pods map[string]struct {
		Rules []struct {
			All  bool `json:"all"`
			From []struct {
				CIDR   string   `json:"cidr"`
				Except []string `json:"except"`
			} `json:"from"`
			Ports []struct {
				Protocol string `json:"protocol"`
				Port     int32  `json:"port"`
				EndPort  int32  `json:"endPort"`
			} `json:"ports"`
		} `json:"rules"`
		HostPorts map[string]int32 `json:"hostPorts"`
	} `json:"pods"`
}

// edgePolicy is that document parsed into what a lookup needs. Only pods that
// some policy isolates for ingress are in it; every other pod is open.
type edgePolicy struct {
	pods map[netip.Addr]*podPolicy
}

type podPolicy struct {
	rules     []edgeRule
	hostPorts map[protoPort]uint16 // host port -> container port
}

type protoPort struct {
	protocol string
	port     uint16
}

type edgeRule struct {
	all   bool
	from  []edgeBlock
	ports []edgePorts // empty: every port
}

type edgeBlock struct {
	prefix netip.Prefix
	except []netip.Prefix
}

type edgePorts struct {
	protocol  string
	low, high uint16 // 0, 0: every port
}

var currentEdgePolicy atomic.Pointer[edgePolicy]

// admits says whether client may open a connection to a pod, over protocol,
// at the port the edge is about to dial. viaHostPort means that port is a
// hostPort, which policy knows by the container port it maps to.
func admits(pod netip.AddrPort, protocol string, client netip.Addr, viaHostPort bool) bool {
	policy := currentEdgePolicy.Load()
	if policy == nil || !pod.IsValid() {
		return true
	}
	p, isolated := policy.pods[pod.Addr()]
	if !isolated {
		return true
	}
	port := pod.Port()
	if viaHostPort {
		mapped, ok := p.hostPorts[protoPort{protocol, port}]
		if !ok {
			return false
		}
		port = mapped
	}
	client = client.Unmap()
	for _, r := range p.rules {
		if r.matches(client, protocol, port) {
			return true
		}
	}
	return false
}

func (r *edgeRule) matches(client netip.Addr, protocol string, port uint16) bool {
	if len(r.ports) > 0 {
		ok := false
		for _, p := range r.ports {
			if p.protocol == protocol && (p.low == 0 || (port >= p.low && port <= p.high)) {
				ok = true
				break
			}
		}
		if !ok {
			return false
		}
	}
	if r.all {
		return true
	}
	for _, block := range r.from {
		if block.prefix.Contains(client) && !anyContains(block.except, client) {
			return true
		}
	}
	return false
}

func anyContains(prefixes []netip.Prefix, a netip.Addr) bool {
	for _, p := range prefixes {
		if p.Contains(a) {
			return true
		}
	}
	return false
}

func parseEdgePolicy(data []byte) (*edgePolicy, error) {
	var doc edgeDocument
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, err
	}
	out := &edgePolicy{pods: map[netip.Addr]*podPolicy{}}
	for address, pod := range doc.Pods {
		ip, err := netip.ParseAddr(address)
		if err != nil {
			continue
		}
		p := &podPolicy{hostPorts: map[protoPort]uint16{}}
		for _, rule := range pod.Rules {
			r := edgeRule{all: rule.All}
			for _, from := range rule.From {
				prefix, err := netip.ParsePrefix(from.CIDR)
				if err != nil {
					continue
				}
				block := edgeBlock{prefix: prefix}
				for _, e := range from.Except {
					if except, err := netip.ParsePrefix(e); err == nil {
						block.except = append(block.except, except)
					}
				}
				r.from = append(r.from, block)
			}
			for _, port := range rule.Ports {
				ports := edgePorts{protocol: port.Protocol, low: uint16(port.Port), high: uint16(port.Port)}
				if port.EndPort > port.Port {
					ports.high = uint16(port.EndPort)
				}
				r.ports = append(r.ports, ports)
			}
			if r.all || len(r.from) > 0 {
				p.rules = append(p.rules, r)
			}
		}
		for key, containerPort := range pod.HostPorts {
			protocol, port, ok := strings.Cut(key, "/")
			number, err := strconv.Atoi(port)
			if ok && err == nil {
				p.hostPorts[protoPort{protocol, uint16(number)}] = uint16(containerPort)
			}
		}
		out.pods[ip] = p
	}
	return out, nil
}

// watchEdgePolicy keeps currentEdgePolicy in step with ferry-netpol, the same
// way ferry-cri follows the pod rules: ask for a newer generation and be held
// until there is one.
//
// The first answer is waited for, briefly, so a restart does not open a window
// in which isolated pods are reachable from outside. If ferry-netpol is not
// there at all, nothing is enforced -- which is also what the pods are doing,
// because they get their rules from the same place.
func watchEdgePolicy(socket string) {
	client := &http.Client{
		Timeout: 40 * time.Second, // ferry-netpol holds a request for 25
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "unix", socket)
			},
		},
	}
	fetch := func(after uint64) (uint64, error) {
		response, err := client.Get(fmt.Sprintf("http://ferry-netpol/edge?after=%d", after))
		if err != nil {
			return after, err
		}
		defer response.Body.Close()
		if response.StatusCode != http.StatusOK {
			return after, fmt.Errorf("ferry-netpol answered %s", response.Status)
		}
		body, err := io.ReadAll(response.Body)
		if err != nil {
			return after, err
		}
		generation, _ := strconv.ParseUint(response.Header.Get("X-Ferry-Generation"), 10, 64)
		if generation == after {
			return after, nil // held until the timeout; nothing changed
		}
		policy, err := parseEdgePolicy(body)
		if err != nil {
			return after, err
		}
		currentEdgePolicy.Store(policy)
		klog.V(2).InfoS("Edge policy updated", "generation", generation, "isolatedPods", len(policy.pods))
		return generation, nil
	}

	ready := make(chan struct{})
	go func() {
		var generation uint64
		first := true
		for {
			next, err := fetch(generation)
			if first {
				first = false
				close(ready)
				if err != nil {
					klog.InfoS("NetworkPolicy is not enforced at the edge until ferry-netpol answers",
						"socket", socket, "err", err)
				}
			}
			if err != nil {
				time.Sleep(3 * time.Second)
				continue
			}
			generation = next
		}
	}()
	select {
	case <-ready:
	case <-time.After(3 * time.Second):
	}
}

// clientAddr is the address a connection came from, for policy.
func clientAddr(a net.Addr) netip.Addr {
	switch v := a.(type) {
	case *net.TCPAddr:
		ip, _ := netip.AddrFromSlice(v.IP)
		return ip.Unmap()
	case *net.UDPAddr:
		ip, _ := netip.AddrFromSlice(v.IP)
		return ip.Unmap()
	}
	return netip.Addr{}
}
