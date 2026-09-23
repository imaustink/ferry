// ferry-proxy is the outside edge of a Service.
//
// NodePort and LoadBalancer both mean "reach this Service from outside the
// cluster", which on a normal node is netfilter in the host's kernel. ferry has
// none on the host and needs none: every pod is a virtual machine with a
// routable address, so the edge is a listener on the Mac that forwards to a
// ready pod.
//
// It also still serves ClusterIPs, but only when asked. That was how Services
// worked before the guest kernel could NAT, and it is now the fallback for a
// kernel that cannot -- ordinarily the rules live in each pod instead.
//
// NodePort needs no privilege: the range is 30000-32767. Nor does a
// LoadBalancer, on any port (expose.go). Loopback aliases for ClusterIPs do.
//
// NetworkPolicy is checked here too, against the client's own address, because
// the pod only ever sees this Mac (policy.go).
package main

import (
	"context"
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	corev1 "k8s.io/api/core/v1"
	discoveryv1 "k8s.io/api/discovery/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	corelisters "k8s.io/client-go/listers/core/v1"
	discoverylisters "k8s.io/client-go/listers/discovery/v1"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/klog/v2"
)

func main() {
	kubeconfig := flag.String("kubeconfig", "", "path to a kubeconfig with cluster-wide read access")
	resync := flag.Duration("resync", 5*time.Minute, "informer resync period")
	clusterIPs := flag.Bool("cluster-ips", false, "also bind ClusterIPs on the host (needs root; only for a guest kernel that cannot NAT)")
	nodePorts := flag.Bool("node-ports", true, "listen on node ports")
	loadBalancerIP := flag.String("load-balancer-ip", "", "address to answer LoadBalancer services on, usually this Mac's LAN address")
	nodeName := flag.String("node-name", "", "this node, so endpoints elsewhere can be told apart from endpoints here")
	hostPortPath := flag.String("host-ports", "", "file ferry-cri writes listing each pod's hostPorts")
	netpolSocket := flag.String("netpol-socket", "", "ferry-netpol's socket, to hold outside clients to NetworkPolicy")
	klog.InitFlags(nil)
	flag.Parse()

	if *kubeconfig == "" {
		fmt.Fprintln(os.Stderr, "--kubeconfig is required")
		os.Exit(2)
	}
	config, err := clientcmd.BuildConfigFromFlags("", *kubeconfig)
	if err != nil {
		klog.ErrorS(err, "Failed to read kubeconfig")
		os.Exit(1)
	}
	client, err := kubernetes.NewForConfig(config)
	if err != nil {
		klog.ErrorS(err, "Failed to build client")
		os.Exit(1)
	}

	ctrl := &controller{
		aliases:        newAliasManager(),
		proxies:        map[string]*serviceProxy{},
		udp:            map[string]*udpProxy{},
		client:         client,
		nodeName:       *nodeName,
		clusterIPs:     *clusterIPs,
		nodePorts:      *nodePorts,
		loadBalancerIP: *loadBalancerIP,
	}

	if *netpolSocket != "" {
		watchEdgePolicy(*netpolSocket)
	}

	// hostPort has nothing to do with Services, so it watches a file rather
	// than the API and runs beside the Service controller instead of inside it.
	newHostPorts(*hostPortPath)

	factory := informers.NewSharedInformerFactory(client, *resync)
	ctrl.services = factory.Core().V1().Services().Lister()
	ctrl.slices = factory.Discovery().V1().EndpointSlices().Lister()
	ctrl.nodes = factory.Core().V1().Nodes().Lister()

	handler := cache.ResourceEventHandlerFuncs{
		AddFunc:    func(any) { ctrl.reconcile() },
		UpdateFunc: func(any, any) { ctrl.reconcile() },
		DeleteFunc: func(any) { ctrl.reconcile() },
	}
	factory.Core().V1().Services().Informer().AddEventHandler(handler)
	factory.Discovery().V1().EndpointSlices().Informer().AddEventHandler(handler)
	factory.Core().V1().Nodes().Informer().AddEventHandler(handler)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	factory.Start(ctx.Done())
	factory.WaitForCacheSync(ctx.Done())
	klog.InfoS("ferry-proxy running")
	ctrl.reconcile()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop

	// Loopback aliases and listeners outlive this process if not cleaned up,
	// and the next run would then fail to bind.
	klog.InfoS("Shutting down; releasing listeners and any ClusterIP aliases")
	ctrl.shutdown()
}

type controller struct {
	mu       sync.Mutex
	aliases  *aliasManager
	proxies  map[string]*serviceProxy
	udp      map[string]*udpProxy
	services corelisters.ServiceLister
	slices   discoverylisters.EndpointSliceLister

	client         kubernetes.Interface
	nodes          corelisters.NodeLister
	nodeName       string
	clusterIPs     bool
	nodePorts      bool
	loadBalancerIP string
	// Ports that could not be bound, so the reason is logged once rather than
	// on every reconcile.
	complained map[string]bool
	// Services already told their SCTP ports have no edge, by service name.
	sctpWarned map[string]bool
}

func (c *controller) shutdown() {
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, p := range c.proxies {
		p.close()
	}
	c.proxies = map[string]*serviceProxy{}
	for _, p := range c.udp {
		p.close()
	}
	c.udp = map[string]*udpProxy{}
	c.aliases.removeAll()
}

// reconcile brings listeners and aliases in line with the Services that
// currently exist. It is cheap enough to run on every event.
func (c *controller) reconcile() {
	c.mu.Lock()
	defer c.mu.Unlock()

	services, err := c.services.List(labels.Everything())
	if err != nil {
		klog.ErrorS(err, "Failed to list services")
		return
	}
	slices, err := c.slices.List(labels.Everything())
	if err != nil {
		klog.ErrorS(err, "Failed to list endpoint slices")
		return
	}

	// Endpoints grouped by service and port name, split by whether the pod is on
	// this Mac. A pod elsewhere cannot be reached from here directly.
	type portKey struct{ service, portName string }
	endpoints := map[portKey][]backend{}
	remoteNodes := map[portKey][]string{}
	nodes := c.nodeAddresses()
	mine := localAddressSet()
	for _, slice := range slices {
		serviceName := slice.Labels[discoveryv1.LabelServiceName]
		if serviceName == "" {
			continue
		}
		service := slice.Namespace + "/" + serviceName
		for _, port := range slice.Ports {
			if port.Port == nil {
				continue
			}
			name := ""
			if port.Name != nil {
				name = *port.Name
			}
			for _, endpoint := range slice.Endpoints {
				// Only endpoints explicitly ready: a nil Ready means unknown,
				// which the API says to treat as ready, but conditions are
				// always set by the endpointslice controller here.
				if endpoint.Conditions.Ready != nil && !*endpoint.Conditions.Ready {
					continue
				}
				key := portKey{service, name}
				// Another node on this Mac counts as this Mac: its vmnet
				// network is the Mac's too, so its pods are dialled directly.
				// Handing them to its node port instead meant dialling our own
				// listener, which forwarded to itself until it ran out of file
				// descriptors -- measured, 850 MB and an empty reply.
				onThisMac := endpoint.NodeName == nil || *endpoint.NodeName == c.nodeName ||
					mine[nodes[*endpoint.NodeName]]
				if !onThisMac {
					remoteNodes[key] = append(remoteNodes[key], *endpoint.NodeName)
					continue
				}
				for _, address := range endpoint.Addresses {
					// A pod on this Mac is reachable at the address the cluster
					// knows it by: its vmnet subnet is this node's slice of the
					// pod network, and the Mac is on that subnet.
					endpoints[key] = append(endpoints[key], podBackend(joinHostPort(address, *port.Port)))
				}
			}
		}
	}

	if c.complained == nil {
		c.complained = map[string]bool{}
	}
	sctpWanted := map[string]bool{}

	desired := map[string]bool{}
	for _, service := range services {
		name := service.Namespace + "/" + service.Name

		// The outside edge: node ports, and a load balancer address when this
		// Mac is standing in for one.
		var wanted []exposure
		if c.nodePorts || c.loadBalancerIP != "" {
			exposures, sctp := exposuresFor(service, c.loadBalancerIP)
			for _, e := range exposures {
				if e.kind == "NodePort" && !c.nodePorts {
					continue
				}
				wanted = append(wanted, e)
			}
			if len(sctp) > 0 {
				// Said once, where `kubectl describe svc` shows it, rather than
				// skipped in silence -- which is what used to happen.
				sctpWanted[name] = true
				if !c.sctpWarned[name] {
					klog.InfoS("SCTP has no host edge on macOS", "service", name, "ports", sctp)
					warnOnService(context.Background(), c.client, service, "SCTPNotServed",
						fmt.Sprintf("ferry cannot serve SCTP on %s: macOS has no SCTP sockets, and raw IP "+
							"needs root. The ClusterIP carries SCTP between pods; reach it from inside the cluster.",
							strings.Join(sctp, ", ")))
				}
			}
		}

		// ClusterIPs, only when the guest kernel cannot do it itself.
		if c.clusterIPs {
			clusterIP := service.Spec.ClusterIP
			// Headless services have no address to bind; DNS resolves them to
			// pod IPs directly, which already route.
			if clusterIP != "" && clusterIP != corev1.ClusterIPNone {
				for _, port := range service.Spec.Ports {
					if port.Protocol != "" && port.Protocol != corev1.ProtocolTCP {
						continue
					}
					wanted = append(wanted, exposure{
						key:      "clusterip/" + name + ":" + strconv.Itoa(int(port.Port)),
						address:  clusterIP,
						port:     port.Port,
						portName: port.Name,
						kind:     "ClusterIP",
					})
				}
			}
		}

		published := false
		for _, e := range wanted {
			desired[e.key] = true
			if _, exists := c.proxies[e.key]; !exists {
				if e.kind == "ClusterIP" {
					if err := c.aliases.ensure(e.address); err != nil {
						klog.ErrorS(err, "Could not bind ClusterIP", "service", name, "ip", e.address)
						continue
					}
				}
				var proxy *serviceProxy
				err := c.ownPortConflict(e)
				if err == nil {
					proxy, err = newServiceProxy(e.key, e.address, e.port, e.protocol, e.only)
				}
				if err != nil {
					// A port somebody else holds is the common case and deserves
					// a sentence, not a stack of identical errors.
					if !c.complained[e.key] {
						c.complained[e.key] = true
						reason, message := listenFailure(e, err)
						klog.ErrorS(err, "Could not listen for service",
							"service", name, "addr", e.describe(), "kind", e.kind, "reason", reason)
						warnOnService(context.Background(), c.client, service, reason, message)
					}
					continue
				}
				c.proxies[e.key] = proxy
				if e.protocol == corev1.ProtocolUDP {
					u, err := newUDPProxy(e.key, e.address, e.port, proxy, e.only)
					if err != nil {
						if !c.complained[e.key] {
							c.complained[e.key] = true
							reason, message := listenFailure(e, err)
							klog.ErrorS(err, "Could not listen for service",
								"service", name, "addr", e.describe(), "kind", e.kind, "protocol", "UDP")
							warnOnService(context.Background(), c.client, service, reason, message)
						}
						delete(c.proxies, e.key)
						continue
					}
					c.udp[e.key] = u
				}
				delete(c.complained, e.key)
				klog.InfoS("Serving", "kind", e.kind, "service", name, "addr", e.describe())
				if proxy.shared {
					warnOnService(context.Background(), c.client, service, "PortShared",
						fmt.Sprintf("another process on this Mac holds *:%d -- on macOS the AirPlay Receiver "+
							"holds 5000 and 7000 -- so ferry answers at %s and on loopback only, ahead of it.",
							e.port, e.describe()))
				}
			}
			pk := portKey{name, e.portName}
			c.proxies[e.key].setBackends(
				chooseBackends(endpoints[pk], remoteNodes[pk], nodes, e.nodePort))

			if e.kind == "LoadBalancer" && !published {
				published = true
				publishLoadBalancer(context.Background(), c.client, service, c.loadBalancerIP)
			}
		}
	}

	c.sctpWarned = sctpWanted

	for key, proxy := range c.proxies {
		if desired[key] {
			continue
		}
		proxy.close()
		delete(c.proxies, key)
		if u, ok := c.udp[key]; ok {
			u.close()
			delete(c.udp, key)
		}
		klog.InfoS("Stopped serving", "service", key)
	}
}

// ownPortConflict refuses a node port or load balancer this process already
// has a wildcard listener on the port of, for another Service.
//
// A listener used to be the arbiter: two Services asking for one port, the
// second failed to bind. With the fallback to particular addresses when the
// wildcard is taken (newServiceProxy), the second would instead bind them and
// quietly take the first one's traffic. So a port that is ours already is
// in use here, before the kernel is asked.
func (c *controller) ownPortConflict(e exposure) error {
	slot := slotOf(e.key)
	if slot == "" {
		return nil
	}
	for key := range c.proxies {
		if key != e.key && slotOf(key) == slot {
			return fmt.Errorf("%s is already served for %s: %w", slot, key, syscall.EADDRINUSE)
		}
	}
	return nil
}

// slotOf is the "port/protocol" a node port or load balancer key listens on,
// both being wildcard listeners.
func slotOf(key string) string {
	if !strings.HasPrefix(key, "nodeport/") && !strings.HasPrefix(key, "loadbalancer/") {
		return ""
	}
	return key[strings.LastIndex(key, ":")+1:]
}

// localAddressSet is every address this Mac answers on.
func localAddressSet() map[string]bool {
	out := map[string]bool{}
	addresses, err := net.InterfaceAddrs()
	if err != nil {
		return out
	}
	for _, a := range addresses {
		if n, ok := a.(*net.IPNet); ok {
			out[n.IP.String()] = true
		}
	}
	return out
}

// nodeAddresses returns where each node can be reached from another Mac.
func (c *controller) nodeAddresses() nodeAddresses {
	out := nodeAddresses{}
	nodes, err := c.nodes.List(labels.Everything())
	if err != nil {
		return out
	}
	for _, node := range nodes {
		for _, address := range node.Status.Addresses {
			if address.Type == corev1.NodeInternalIP && address.Address != "" {
				out[node.Name] = address.Address
				break
			}
		}
	}
	return out
}

func joinHostPort(host string, port int32) string {
	return host + ":" + strconv.Itoa(int(port))
}
