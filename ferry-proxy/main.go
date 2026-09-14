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
// NodePort needs no privilege: the range is 30000-32767. Loopback aliases for
// ClusterIPs do, and so does a LoadBalancer port below 1024.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strconv"
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
				onThisMac := endpoint.NodeName == nil || *endpoint.NodeName == c.nodeName
				if !onThisMac {
					remoteNodes[key] = append(remoteNodes[key], *endpoint.NodeName)
					continue
				}
				for _, address := range endpoint.Addresses {
					// A pod on this Mac is reachable at the address the cluster
					// knows it by: its vmnet subnet is this node's slice of the
					// pod network, and the Mac is on that subnet.
					endpoints[key] = append(endpoints[key], backend{
						address: joinHostPort(address, *port.Port),
					})
				}
			}
		}
	}

	if c.complained == nil {
		c.complained = map[string]bool{}
	}

	desired := map[string]bool{}
	for _, service := range services {
		name := service.Namespace + "/" + service.Name

		// The outside edge: node ports, and a load balancer address when this
		// Mac is standing in for one.
		var wanted []exposure
		if c.nodePorts || c.loadBalancerIP != "" {
			for _, e := range exposuresFor(service, c.loadBalancerIP) {
				if e.kind == "NodePort" && !c.nodePorts {
					continue
				}
				wanted = append(wanted, e)
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

		// A Service asking for SCTP on the outside edge gets an explanation
		// rather than silence. Its ClusterIP still works.
		for _, port := range service.Spec.Ports {
			if port.Protocol != corev1.ProtocolSCTP {
				continue
			}
			if service.Spec.Type != corev1.ServiceTypeNodePort &&
				service.Spec.Type != corev1.ServiceTypeLoadBalancer {
				continue
			}
			key := fmt.Sprintf("sctp/%s:%d", name, port.Port)
			if !c.complained[key] {
				c.complained[key] = true
				klog.InfoS("SCTP is not served on the node edge; the ClusterIP still works",
					"service", name, "port", port.Port, "type", service.Spec.Type)
				warnOnService(context.Background(), c.client, service, "SCTPNotExposed",
					fmt.Sprintf("ferry cannot expose SCTP port %d as %s: macOS has no SCTP "+
						"sockets, so the Mac cannot listen for it. Pod-to-pod SCTP works, "+
						"including through this Service's ClusterIP.",
						port.Port, service.Spec.Type))
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
				proxy, err := newServiceProxy(e.key, e.address, e.port, e.protocol)
				if err != nil {
					// A privileged port without privilege is the common case and
					// deserves a sentence, not a stack of identical errors.
					if !c.complained[e.key] {
						c.complained[e.key] = true
						if e.port < 1024 {
							klog.ErrorS(err, "Could not listen on a privileged port; run ferry-proxy as root to serve it",
								"service", name, "addr", e.describe(), "kind", e.kind)
							warnOnService(context.Background(), c.client, service, "PortNotPermitted",
								fmt.Sprintf("ferry cannot listen on %s: ports below 1024 need root. "+
									"Restart the cluster with 'FERRY_HOST_CLUSTER_IPS=1 ferry up', which runs "+
									"ferry-proxy under sudo, or reach this Service on its node port instead.",
									e.describe()))
						} else {
							klog.ErrorS(err, "Could not listen for service",
								"service", name, "addr", e.describe(), "kind", e.kind)
							warnOnService(context.Background(), c.client, service, "ListenFailed",
								fmt.Sprintf("ferry could not listen on %s: %v", e.describe(), err))
						}
					}
					continue
				}
				c.proxies[e.key] = proxy
				if e.protocol == corev1.ProtocolUDP {
					u, err := newUDPProxy(e.key, e.address, e.port, proxy)
					if err != nil {
						if !c.complained[e.key] {
							c.complained[e.key] = true
							klog.ErrorS(err, "Could not listen for service",
								"service", name, "addr", e.describe(), "kind", e.kind, "protocol", "UDP")
						}
						delete(c.proxies, e.key)
						continue
					}
					c.udp[e.key] = u
				}
				delete(c.complained, e.key)
				klog.InfoS("Serving", "kind", e.kind, "service", name, "addr", e.describe())
			}
			pk := portKey{name, e.portName}
			c.proxies[e.key].setBackends(
				chooseBackends(endpoints[pk], remoteNodes[pk], c.nodeAddresses(), e.nodePort))

			if e.kind == "LoadBalancer" && !published {
				published = true
				publishLoadBalancer(context.Background(), c.client, service, c.loadBalancerIP)
			}
		}
	}

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
