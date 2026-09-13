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
// reserved. A LoadBalancer whose port is below 1024 does, and says so rather
// than failing silently.

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"

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
		out = append(out, backend{address: address + ":" + strconv.Itoa(int(nodePort))})
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
}

// exposuresFor returns what the Mac should listen on for one Service.
func exposuresFor(service *corev1.Service, loadBalancerIP string) []exposure {
	var out []exposure
	name := service.Namespace + "/" + service.Name

	for _, port := range service.Spec.Ports {
		if port.Protocol != "" && port.Protocol != corev1.ProtocolTCP {
			continue // UDP and SCTP are not forwarded; see docs/SERVICES.md
		}

		// NodePort is allocated for both NodePort and LoadBalancer services.
		if port.NodePort != 0 {
			out = append(out, exposure{
				key:      fmt.Sprintf("nodeport/%s:%d", name, port.NodePort),
				address:  "", // every interface: the Mac is the node
				port:     port.NodePort,
				portName: port.Name,
				kind:     "NodePort",
				nodePort: port.NodePort,
			})
		}

		if service.Spec.Type == corev1.ServiceTypeLoadBalancer && loadBalancerIP != "" {
			out = append(out, exposure{
				key:      fmt.Sprintf("loadbalancer/%s:%d", name, port.Port),
				address:  loadBalancerIP,
				port:     port.Port,
				portName: port.Name,
				kind:     "LoadBalancer",
				nodePort: port.NodePort,
			})
		}
	}
	return out
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
	if e.address == "" {
		return ":" + strconv.Itoa(int(e.port))
	}
	return e.address + ":" + strconv.Itoa(int(e.port))
}
