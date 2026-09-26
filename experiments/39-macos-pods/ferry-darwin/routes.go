package main

// Return routes to the other machines, scoped to the pod card.
//
// A Linux machine reaches this node's pods the way it reaches another Linux
// machine's: its route agent routes this node's pod slice via this node's
// machine-network address, and masquerades, so a pod's SYN arrives on the
// machine card from the Linux machine's own address. The pod's socket is bound
// to its address, which lives on the pod card, and macOS scopes a bound
// socket's routes to that address's interface -- so the reply was routed only
// among the pod card's routes, found none to the machine network, and was
// dropped before it left. (First the strong host check had dropped the SYN
// itself; see setPodCIDR.)
//
// A route in the pod card's scope for the machine network through the machine
// card is refused ("Network is unreachable": a scope cannot leave its
// interface). But every machine is also on the pod switch, at .1 of its slice,
// so a host route in the pod card's scope -- the Linux machine's address, via
// its pod-switch address -- takes the reply back over the pod switch, and the
// Linux machine, weak-host as Linux is, takes it and matches it to the
// connection. This keeps one such route per node on the machine network, from
// the Node list, the way a Linux machine's route agent keeps its own.

import (
	"fmt"
	"log"
	"net"
	"os/exec"
	"strings"
)

type k8sNode struct {
	Metadata struct{ Name string } `json:"metadata"`
	Spec     struct {
		PodCIDR string `json:"podCIDR"`
	} `json:"spec"`
	Status struct {
		Addresses []struct{ Type, Address string } `json:"addresses"`
	} `json:"status"`
}

// onMachineNetwork is whether ip is directly reachable from one of the node's
// cards other than the pod card: the peers whose replies need a route.
func (n *node) onMachineNetwork(ip net.IP) bool {
	ifaces, err := net.Interfaces()
	if err != nil {
		return false
	}
	for _, ifc := range ifaces {
		if ifc.Name == n.iface || ifc.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, _ := ifc.Addrs()
		for _, a := range addrs {
			if ipn, ok := a.(*net.IPNet); ok && ipn.IP.To4() != nil && ipn.Contains(ip) {
				return true
			}
		}
	}
	return false
}

// syncPeerRoutes makes the scoped host routes match the Node list.
func (t *serviceTable) syncPeerRoutes(nodes []k8sNode) {
	n := t.rt.node
	if n.clusterCIDR == nil || t.nodeName == "" {
		return
	}
	want := map[string]string{} // peer's machine address -> its pod-switch address
	for _, node := range nodes {
		if node.Metadata.Name == t.nodeName || node.Spec.PodCIDR == "" {
			continue
		}
		var internal net.IP
		for _, a := range node.Status.Addresses {
			if a.Type == "InternalIP" {
				internal = net.ParseIP(a.Address).To4()
			}
		}
		_, slice, err := net.ParseCIDR(node.Spec.PodCIDR)
		if internal == nil || err != nil || !n.onMachineNetwork(internal) {
			continue
		}
		s := slice.IP.To4()
		want[internal.String()] = net.IPv4(s[0], s[1], s[2], s[3]+1).String()
	}
	for ip, gw := range want {
		if t.peerRoutes[ip] == gw {
			continue
		}
		_ = exec.Command("route", "-q", "-n", "delete", "-ifscope", n.iface, "-host", ip).Run()
		if out, err := exec.Command("route", "-q", "-n", "add", "-ifscope", n.iface, "-host", ip, gw).CombinedOutput(); err != nil {
			log.Printf("routes: %s via %s: %v: %s", ip, gw, err, strings.TrimSpace(string(out)))
			continue
		}
		t.peerRoutes[ip] = gw
		log.Printf("routes: replies to %s go back by the pod switch, via %s", ip, gw)
	}
	for ip := range t.peerRoutes {
		if _, ok := want[ip]; !ok {
			_ = exec.Command("route", "-q", "-n", "delete", "-ifscope", n.iface, "-host", ip).Run()
			delete(t.peerRoutes, ip)
			log.Printf("routes: %s is gone", ip)
		}
	}
}

func (t *serviceTable) refreshNodes() error {
	var nodes struct{ Items []k8sNode }
	if err := t.get("/api/v1/nodes", &nodes); err != nil {
		return fmt.Errorf("nodes: %w", err)
	}
	t.syncPeerRoutes(nodes.Items)
	return nil
}
