// ferry-netpol enforces NetworkPolicy in the only place that can see the traffic.
//
// A NetworkPolicy is per pod: this pod accepts from those pods, on these ports.
// On an ordinary cluster a CNI plugin enforces that somewhere in the host's
// kernel, and ferry has no such place -- there is no CNI here, and the Mac is not
// on the pod network at all.
//
// But every ferry pod is a virtual machine with its own Linux kernel, and ferry
// already puts nftables rules into those kernels: that is how Services work. A
// per-pod policy wants a per-pod firewall, and a per-pod firewall is exactly what
// a machine per pod gives you for free. So the rules are worked out here, where
// the cluster can be watched, and applied there, where the packets are.
//
// Until this existed, NetworkPolicy objects were accepted and silently ignored --
// a cluster that takes a deny-all policy and keeps forwarding everything is
// worse than one that has no policies at all.
package main

import (
	"context"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"syscall"
	"time"

	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/klog/v2"
)

func main() {
	kubeconfig := flag.String("kubeconfig", "", "kubeconfig with read access to policies, pods and namespaces")
	socketPath := flag.String("socket", "/tmp/ferry-netpol.sock", "socket to serve rules on")
	clusterCIDR := flag.String("cluster-cidr", "10.244.0.0/16", "the pod network these rules govern")
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

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	server := &ruleServer{changed: make(chan struct{}), contentType: "text/plain"}
	// The same rules, for ferry-proxy to hold connections from outside the
	// cluster to. A pod sees every such connection arrive from its node, so the
	// only place the real client is known is the edge that accepted it.
	edge := &ruleServer{changed: make(chan struct{}), contentType: "application/json"}
	compiler := &compiler{clusterCIDR: *clusterCIDR}

	factory := informers.NewSharedInformerFactory(client, *resync)
	compiler.policies = factory.Networking().V1().NetworkPolicies().Lister()
	compiler.pods = factory.Core().V1().Pods().Lister()
	compiler.namespaces = factory.Core().V1().Namespaces().Lister()
	compiler.nodes = factory.Core().V1().Nodes().Lister()

	rebuild := func() {
		rules, document := compiler.render()
		server.publish(rules)
		edge.publish(string(document))
	}
	handler := cache.ResourceEventHandlerFuncs{
		AddFunc:    func(any) { rebuild() },
		UpdateFunc: func(any, any) { rebuild() },
		DeleteFunc: func(any) { rebuild() },
	}
	factory.Networking().V1().NetworkPolicies().Informer().AddEventHandler(handler)
	factory.Core().V1().Pods().Informer().AddEventHandler(handler)
	factory.Core().V1().Namespaces().Informer().AddEventHandler(handler)
	// Nodes matter because a pod's own node's address on the pod network is
	// exempt from ingress policy, and that address comes from its podCIDR.
	factory.Core().V1().Nodes().Informer().AddEventHandler(handler)

	factory.Start(ctx.Done())
	factory.WaitForCacheSync(ctx.Done())
	rebuild()

	_ = os.Remove(*socketPath)
	listener, err := net.Listen("unix", *socketPath)
	if err != nil {
		klog.ErrorS(err, "Failed to listen", "socket", *socketPath)
		os.Exit(1)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/rules", server.serve)
	mux.HandleFunc("/edge", edge.serve)
	go http.Serve(listener, mux)

	fmt.Printf("==> ferry-netpol\n    rules     unix://%s\n    network   %s\n    serving\n",
		*socketPath, *clusterCIDR)

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop
	_ = os.Remove(*socketPath)
}

// ruleServer hands out the current rules and holds a caller that already has
// them until they change, the same bargain ferry-proxyd offers for Services.
type ruleServer struct {
	contentType string

	mu         sync.RWMutex
	rules      string
	generation uint64
	changed    chan struct{}
}

func (s *ruleServer) publish(rules string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if rules == s.rules {
		return
	}
	s.rules = rules
	s.generation++
	close(s.changed)
	s.changed = make(chan struct{})
	klog.V(2).InfoS("Rendered policy rules", "generation", s.generation, "bytes", len(rules))
}

func (s *ruleServer) current() (string, uint64, chan struct{}) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.rules, s.generation, s.changed
}

func (s *ruleServer) serve(w http.ResponseWriter, r *http.Request) {
	rules, generation, changed := s.current()
	if after := r.URL.Query().Get("after"); after != "" {
		if want, err := strconv.ParseUint(after, 10, 64); err == nil && generation <= want {
			timeout := time.NewTimer(25 * time.Second)
			defer timeout.Stop()
			select {
			case <-changed:
				rules, generation, _ = s.current()
			case <-timeout.C:
			case <-r.Context().Done():
				return
			}
		}
	}
	w.Header().Set("X-Ferry-Generation", strconv.FormatUint(generation, 10))
	w.Header().Set("Content-Type", s.contentType)
	fmt.Fprint(w, rules)
}
