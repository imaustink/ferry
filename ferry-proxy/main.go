// ferry-proxy makes ClusterIPs reachable.
//
// It watches Services and EndpointSlices, binds each ClusterIP as a loopback
// alias so the kernel accepts traffic addressed to it, and forwards connections
// to a ready endpoint. Pods already default-route to the Mac, so nothing has to
// be configured inside them.
//
// Root is required for exactly two things: adding loopback aliases, and
// listening on privileged ports (the kubernetes Service is 443).
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
	corelisters "k8s.io/client-go/listers/core/v1"
	discoverylisters "k8s.io/client-go/listers/discovery/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/klog/v2"
)

func main() {
	kubeconfig := flag.String("kubeconfig", "", "path to a kubeconfig with cluster-wide read access")
	resync := flag.Duration("resync", 5*time.Minute, "informer resync period")
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
		aliases: newAliasManager(),
		proxies: map[string]*serviceProxy{},
	}

	factory := informers.NewSharedInformerFactory(client, *resync)
	ctrl.services = factory.Core().V1().Services().Lister()
	ctrl.slices = factory.Discovery().V1().EndpointSlices().Lister()

	handler := cache.ResourceEventHandlerFuncs{
		AddFunc:    func(any) { ctrl.reconcile() },
		UpdateFunc: func(any, any) { ctrl.reconcile() },
		DeleteFunc: func(any) { ctrl.reconcile() },
	}
	factory.Core().V1().Services().Informer().AddEventHandler(handler)
	factory.Discovery().V1().EndpointSlices().Informer().AddEventHandler(handler)

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
	klog.InfoS("Shutting down; releasing ClusterIP aliases")
	ctrl.shutdown()
}

type controller struct {
	mu       sync.Mutex
	aliases  *aliasManager
	proxies  map[string]*serviceProxy
	services corelisters.ServiceLister
	slices   discoverylisters.EndpointSliceLister
}

func (c *controller) shutdown() {
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, p := range c.proxies {
		p.close()
	}
	c.proxies = map[string]*serviceProxy{}
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

	// Endpoints grouped by service and port name.
	type portKey struct{ service, portName string }
	endpoints := map[portKey][]backend{}
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
				for _, address := range endpoint.Addresses {
					key := portKey{service, name}
					endpoints[key] = append(endpoints[key], backend{
						address: joinHostPort(address, *port.Port),
					})
				}
			}
		}
	}

	desired := map[string]bool{}
	for _, service := range services {
		clusterIP := service.Spec.ClusterIP
		// Headless services have no address to bind; DNS resolves them to pod
		// IPs directly, which already route.
		if clusterIP == "" || clusterIP == corev1.ClusterIPNone {
			continue
		}
		name := service.Namespace + "/" + service.Name
		for _, port := range service.Spec.Ports {
			if port.Protocol != "" && port.Protocol != corev1.ProtocolTCP {
				// UDP and SCTP are not proxied yet; see docs/SERVICES.md.
				continue
			}
			key := name + ":" + strconv.Itoa(int(port.Port))
			desired[key] = true

			if _, exists := c.proxies[key]; !exists {
				if err := c.aliases.ensure(clusterIP); err != nil {
					klog.ErrorS(err, "Could not bind ClusterIP", "service", name, "ip", clusterIP)
					continue
				}
				proxy, err := newServiceProxy(key, clusterIP, port.Port)
				if err != nil {
					klog.ErrorS(err, "Could not listen for service", "service", name, "addr", clusterIP)
					continue
				}
				c.proxies[key] = proxy
				klog.InfoS("Serving ClusterIP", "service", name, "addr", proxy.listen)
			}
			c.proxies[key].setBackends(endpoints[portKey{name, port.Name}])
		}
	}

	for key, proxy := range c.proxies {
		if desired[key] {
			continue
		}
		proxy.close()
		delete(c.proxies, key)
		klog.InfoS("Stopped serving ClusterIP", "service", key)
	}
}

func joinHostPort(host string, port int32) string {
	return host + ":" + strconv.Itoa(int(port))
}
