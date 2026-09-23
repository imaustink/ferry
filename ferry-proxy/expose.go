package main

// NodePort and LoadBalancer, on a Mac.
//
// Both mean the same thing in Kubernetes: reach this Service from outside the
// cluster. On a normal node kube-proxy arranges that with netfilter rules in the
// host's kernel. ferry has no netfilter on the host -- but it does not need any,
// because every pod is a virtual machine with a routable address and the Mac can
// already reach it. So the outside edge of a Service is a listener on the Mac
// that forwards to a ready pod.
//
// NodePort asks for no privilege: the range is 30000-32767 and nothing there is
// reserved. Neither does a LoadBalancer, even on 80 and 443: macOS has not
// reserved ports below 1024 on the wildcard address since Mojave, only on a
// particular one. So a LoadBalancer listens on the wildcard and answers only
// connections that arrived at the addresses it is published on -- this Mac's
// LAN address, and loopback, so localhost:80 works the way it does under
// Docker Desktop. Verified as uid 501: 0.0.0.0:80 and [::]:80 bind, TCP and
// UDP; 192.168.1.29:80 is EACCES.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"strconv"
	"syscall"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes"
	"k8s.io/klog/v2"
)

// nodeAddresses maps a node name to an address other Macs can reach it at.
type nodeAddresses map[string]string

// chooseBackends decides where a connection arriving at the Mac should go.
//
// A pod on this Mac is reachable directly: it has a routable address and the Mac
// is on its vmnet network. A pod on another Mac is not -- the cluster network
// that carries pod-to-pod traffic is between pods, and the host is not on it. So
// for those, the connection is handed to the Mac that does have the pod, at the
// same node port, and that Mac forwards it the last hop.
//
// This is what kube-proxy does for a NodePort with the default traffic policy,
// arrived at for the same reason.
func chooseBackends(local []backend, remoteNodes []string, nodes nodeAddresses, nodePort int32) []backend {
	out := append([]backend{}, local...)
	if nodePort == 0 {
		// No node port to forward to, so only pods on this Mac can be served.
		return out
	}
	seen := map[string]bool{}
	for _, node := range remoteNodes {
		address := nodes[node]
		if address == "" || seen[address] {
			continue
		}
		seen[address] = true
		out = append(out, backend{address: address + ":" + strconv.Itoa(int(nodePort))}) // no pod: that node checks policy
	}
	return out
}

// exposure is one address:port the Mac listens on for a Service.
type exposure struct {
	key      string // stable identity, so reconcile knows what already exists
	address  string // "" means every interface
	port     int32
	portName string // which of the Service's ports the endpoints come from
	kind     string // for logging: "NodePort" or "LoadBalancer"
	nodePort int32  // where to hand a connection whose pod lives on another Mac
	protocol corev1.Protocol
	only     localAddresses // a wildcard listener answering on these alone
	shown    string         // for logging, when address is "" but only is not
}

// loadBalancerAddresses is where a LoadBalancer answers: the address it is
// published at, and loopback.
func loadBalancerAddresses(ip string) localAddresses {
	out := localAddresses{netip.MustParseAddr("127.0.0.1"), netip.IPv6Loopback()}
	if a, err := netip.ParseAddr(ip); err == nil {
		out = append(out, a.Unmap())
	}
	return out
}

// exposuresFor returns what the Mac should listen on for one Service, and the
// SCTP ports it cannot.
func exposuresFor(service *corev1.Service, loadBalancerIP string) (out []exposure, sctp []string) {
	name := service.Namespace + "/" + service.Name

	for _, port := range service.Spec.Ports {
		protocol := corev1.ProtocolTCP
		if port.Protocol != "" {
			protocol = port.Protocol
		}
		if protocol != corev1.ProtocolTCP && protocol != corev1.ProtocolUDP {
			// macOS has no SCTP sockets, and raw IP needs root. The ClusterIP
			// carries SCTP between pods; the Mac cannot be its edge.
			if port.NodePort != 0 {
				sctp = append(sctp, fmt.Sprintf("node port %d", port.NodePort))
			}
			if service.Spec.Type == corev1.ServiceTypeLoadBalancer && loadBalancerIP != "" {
				sctp = append(sctp, fmt.Sprintf("%s:%d", loadBalancerIP, port.Port))
			}
			continue
		}

		// NodePort is allocated for both NodePort and LoadBalancer services.
		if port.NodePort != 0 {
			out = append(out, exposure{
				key:      fmt.Sprintf("nodeport/%s:%d/%s", name, port.NodePort, protocol),
				address:  "", // every interface: the Mac is the node
				port:     port.NodePort,
				portName: port.Name,
				kind:     "NodePort",
				nodePort: port.NodePort,
				protocol: protocol,
			})
		}

		if service.Spec.Type == corev1.ServiceTypeLoadBalancer && loadBalancerIP != "" {
			out = append(out, exposure{
				key:      fmt.Sprintf("loadbalancer/%s:%d/%s", name, port.Port, protocol),
				address:  "", // the wildcard, narrowed: see the top of this file
				port:     port.Port,
				portName: port.Name,
				kind:     "LoadBalancer",
				nodePort: port.NodePort,
				protocol: protocol,
				only:     loadBalancerAddresses(loadBalancerIP),
				shown:    loadBalancerIP,
			})
		}
	}
	return out, sctp
}

// publishLoadBalancer tells the cluster where a LoadBalancer Service answers.
// Without this the Service sits at <pending> forever, which is the usual
// experience of asking for a LoadBalancer on a laptop.
func publishLoadBalancer(ctx context.Context, client kubernetes.Interface, service *corev1.Service, ip string) {
	for _, existing := range service.Status.LoadBalancer.Ingress {
		if existing.IP == ip {
			return
		}
	}
	patch, err := json.Marshal(map[string]any{
		"status": map[string]any{
			"loadBalancer": map[string]any{
				"ingress": []map[string]string{{"ip": ip}},
			},
		},
	})
	if err != nil {
		return
	}
	_, err = client.CoreV1().Services(service.Namespace).
		Patch(ctx, service.Name, types.MergePatchType, patch, metav1.PatchOptions{}, "status")
	if err != nil {
		klog.ErrorS(err, "Could not publish the load balancer address",
			"service", service.Namespace+"/"+service.Name, "ip", ip)
		return
	}
	klog.InfoS("Published load balancer address",
		"service", service.Namespace+"/"+service.Name, "ip", ip)
}

// describe is what a person sees in the log.
func (e exposure) describe() string {
	if e.address == "" && e.shown != "" {
		return e.shown + ":" + strconv.Itoa(int(e.port))
	}
	if e.address == "" {
		return ":" + strconv.Itoa(int(e.port))
	}
	return e.address + ":" + strconv.Itoa(int(e.port))
}

// listenFailure is the Event for a port that could not be opened. Almost
// always it is another process holding the port -- another ferry cluster, a
// Docker Desktop publishing the same one, a web server -- and naming the
// command that finds it saves a person the search.
func listenFailure(e exposure, err error) (reason, message string) {
	port := strconv.Itoa(int(e.port))
	proto := "TCP"
	if e.protocol == corev1.ProtocolUDP {
		proto = "UDP"
	}
	switch {
	case errors.Is(err, syscall.EADDRINUSE):
		return "PortInUse", fmt.Sprintf("ferry cannot listen on %s: another process on this Mac already has "+
			"port %s. 'lsof -nP -i%s:%s' shows which; stop it, or reach this Service on its node port.",
			e.describe(), port, proto, port)
	case errors.Is(err, syscall.EACCES):
		return "PortNotPermitted", fmt.Sprintf("ferry cannot listen on %s: macOS reserves ports below 1024 "+
			"on a particular address for root. Reach this Service on its node port instead.", e.describe())
	}
	return "ListenFailed", fmt.Sprintf("ferry could not listen on %s: %v", e.describe(), err)
}

// warnOnService puts a reason where a person will look for it.
//
// A LoadBalancer that cannot open its port stays at <pending> forever, and until
// now the only explanation was a line in ferry-proxy's log -- which is on the
// Mac, not in the cluster, and which nobody reads unless they already suspect
// the answer is there. `kubectl describe svc` is where that question gets asked,
// so the answer is written there as an Event.
//
// Events are deduplicated by the API server on count, so repeating one is
// cheap; the caller still rate-limits itself so a tight loop does not write one
// per pass.
func warnOnService(ctx context.Context, client kubernetes.Interface,
	service *corev1.Service, reason, message string) {

	now := metav1.Now()
	event := &corev1.Event{
		ObjectMeta: metav1.ObjectMeta{
			GenerateName: service.Name + ".",
			Namespace:    service.Namespace,
		},
		InvolvedObject: corev1.ObjectReference{
			Kind:            "Service",
			Namespace:       service.Namespace,
			Name:            service.Name,
			UID:             service.UID,
			APIVersion:      "v1",
			ResourceVersion: service.ResourceVersion,
		},
		Reason:         reason,
		Message:        message,
		Type:           corev1.EventTypeWarning,
		Source:         corev1.EventSource{Component: "ferry-proxy"},
		FirstTimestamp: now,
		LastTimestamp:  now,
		Count:          1,
	}
	if _, err := client.CoreV1().Events(service.Namespace).Create(ctx, event, metav1.CreateOptions{}); err != nil {
		klog.V(2).ErrorS(err, "Could not record an event on the service",
			"service", service.Namespace+"/"+service.Name, "reason", reason)
	}
}
