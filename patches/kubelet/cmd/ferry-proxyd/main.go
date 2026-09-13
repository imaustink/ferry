//go:build darwin

// ferry-proxyd runs kube-proxy's rule generation on macOS and renders the
// ruleset instead of applying it.
//
// There is no kernel on the host to program, but every pod has one. So the
// generation runs here -- unmodified kube-proxy code, with all of its semantics:
// reject rules for Services with no endpoints, hairpin masquerade, session
// affinity, endpoint selection -- and ferry pushes the result into each pod.
//
// This proves the mechanism: construct the proxier, feed it a Service and its
// endpoints, sync, and print what it would have programmed.
package main

import (
	"context"
	"fmt"
	"net"
	"os"
	"time"

	v1 "k8s.io/api/core/v1"
	discoveryv1 "k8s.io/api/discovery/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/kubernetes/pkg/proxy/nftables"
	proxyutil "k8s.io/kubernetes/pkg/proxy/util"
)

func main() {
	ctx := context.Background()
	proxier, err := nftables.NewProxier(ctx,
		v1.IPv4Protocol,
		30*time.Second, // syncPeriod
		time.Second,    // minSyncPeriod
		false,          // masqueradeAll
		14,             // masqueradeBit
		proxyutil.NewNoOpLocalDetector(),
		"ferry-mac",
		net.ParseIP("192.168.122.1"),
		nil, // recorder
		nil, // healthzServer
		nil, // nodePortAddresses
		false,
	)
	if err != nil {
		fmt.Fprintf(os.Stderr, "create proxier: %v\n", err)
		os.Exit(1)
	}

	tcp := v1.ProtocolTCP
	proxier.OnServiceAdd(&v1.Service{
		ObjectMeta: metav1.ObjectMeta{Name: "backend", Namespace: "default"},
		Spec: v1.ServiceSpec{
			ClusterIP: "10.96.107.164",
			Type:      v1.ServiceTypeClusterIP,
			Ports:     []v1.ServicePort{{Name: "http", Port: 80, Protocol: tcp}},
		},
	})
	// A second Service with no endpoints, to show the reject rule appear.
	proxier.OnServiceAdd(&v1.Service{
		ObjectMeta: metav1.ObjectMeta{Name: "lonely", Namespace: "default"},
		Spec: v1.ServiceSpec{
			ClusterIP: "10.96.200.200",
			Type:      v1.ServiceTypeClusterIP,
			Ports:     []v1.ServicePort{{Name: "http", Port: 80, Protocol: tcp}},
		},
	})

	ready := true
	port := int32(8080)
	name := "http"
	proxier.OnEndpointSliceAdd(&discoveryv1.EndpointSlice{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "backend-abc",
			Namespace: "default",
			Labels:    map[string]string{discoveryv1.LabelServiceName: "backend"},
		},
		AddressType: discoveryv1.AddressTypeIPv4,
		Ports:       []discoveryv1.EndpointPort{{Name: &name, Port: &port, Protocol: &tcp}},
		Endpoints: []discoveryv1.Endpoint{
			{Addresses: []string{"192.168.122.3"}, Conditions: discoveryv1.EndpointConditions{Ready: &ready}},
			{Addresses: []string{"192.168.122.4"}, Conditions: discoveryv1.EndpointConditions{Ready: &ready}},
		},
	})

	proxier.OnServiceSynced()
	proxier.OnEndpointSlicesSynced()
	proxier.Sync()
	time.Sleep(2 * time.Second)

	if nftables.FerryRendered == nil {
		fmt.Fprintln(os.Stderr, "no ruleset was rendered")
		os.Exit(1)
	}
	fmt.Print(nftables.FerryRendered.Dump())
}
