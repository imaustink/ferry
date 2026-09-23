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
//
// It compiles on the control plane's Mac only, with the cluster's own
// credentials. Every other Mac runs it as a follower (follow.go), which asks
// the control plane for its own nodes' rules over TLS and serves them locally
// in the same forms; serve.go says why.
package main

import (
	"context"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/klog/v2"
)

// repeated is a flag that may be given more than once.
type repeated []string

func (r *repeated) String() string     { return strings.Join(*r, ",") }
func (r *repeated) Set(v string) error { *r = append(*r, v); return nil }

func main() {
	kubeconfig := flag.String("kubeconfig", "", "the control plane's kubeconfig, with read access to policies, pods, namespaces and nodes")
	socketPath := flag.String("socket", "/tmp/ferry-netpol.sock", "socket to serve rules on")
	clusterCIDR := flag.String("cluster-cidr", "10.244.0.0/16", "the pod network these rules govern")
	resync := flag.Duration("resync", 5*time.Minute, "informer resync period")
	listen := flag.String("listen", "", "serve other Macs' nodes their own rules over TLS here, e.g. 0.0.0.0:6444")
	tlsCert := flag.String("tls-cert", "", "the certificate --listen presents: the API server's")
	tlsKey := flag.String("tls-key", "", "its key")
	clientCA := flag.String("client-ca", "", "the cluster CA, which a node's certificate must be signed by")
	upstreamAddr := flag.String("upstream", "", "follow the control plane's ferry-netpol at host:port instead of compiling")
	var nodeKubeconfigs repeated
	flag.Var(&nodeKubeconfigs, "node-kubeconfig", "with --upstream: the kubeconfig of a node on this Mac to follow as; once per node")
	klog.InitFlags(nil)
	flag.Parse()

	rules := newRuleServer("text/plain")
	// The same rules, for ferry-proxy to hold connections from outside the
	// cluster to. A pod sees every such connection arrive from its node, so the
	// only place the real client is known is the edge that accepted it.
	edge := newRuleServer("application/json")

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var mode string
	switch {
	case *upstreamAddr != "":
		if len(nodeKubeconfigs) == 0 {
			fmt.Fprintln(os.Stderr, "--upstream needs at least one --node-kubeconfig")
			os.Exit(2)
		}
		var upstreams []*upstream
		var names []string
		for _, path := range nodeKubeconfigs {
			u, err := newUpstream(path, *upstreamAddr)
			if err != nil {
				klog.ErrorS(err, "Failed to read a node's credentials", "kubeconfig", path)
				os.Exit(1)
			}
			upstreams = append(upstreams, u)
			names = append(names, u.node)
		}
		newFollower(upstreams, rules, edge).start()
		mode = fmt.Sprintf("    upstream  https://%s\n    as        %s\n", *upstreamAddr, strings.Join(names, ", "))
	case *kubeconfig != "":
		views := newNodeViews()
		if err := compileCluster(ctx, *kubeconfig, *clusterCIDR, *resync, rules, edge, views); err != nil {
			os.Exit(1)
		}
		if *listen != "" {
			config, err := peerTLS(*tlsCert, *tlsKey, *clientCA)
			if err != nil {
				klog.ErrorS(err, "Failed to load the peer port's certificates")
				os.Exit(1)
			}
			listener, err := net.Listen("tcp", *listen)
			if err != nil {
				klog.ErrorS(err, "Failed to listen for other Macs", "address", *listen)
				os.Exit(1)
			}
			server := &http.Server{Handler: views.handler(), TLSConfig: config,
				ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 2 * time.Minute}
			go server.ServeTLS(listener, "", "")
			mode = fmt.Sprintf("    nodes     https://%s\n", *listen)
		}
	default:
		fmt.Fprintln(os.Stderr, "--kubeconfig, or --upstream with --node-kubeconfig, is required")
		os.Exit(2)
	}

	_ = os.Remove(*socketPath)
	listener, err := net.Listen("unix", *socketPath)
	if err != nil {
		klog.ErrorS(err, "Failed to listen", "socket", *socketPath)
		os.Exit(1)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/rules", rules.serve)
	mux.HandleFunc("/edge", edge.serve)
	go http.Serve(listener, mux)

	fmt.Printf("==> ferry-netpol\n    rules     unix://%s\n%s    network   %s\n    serving\n",
		*socketPath, mode, *clusterCIDR)

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop
	_ = os.Remove(*socketPath)
}

// compileCluster watches the cluster and keeps rules, edge and every node's
// view current. It returns once the first compilation is published.
//
// Events are coalesced: an event only marks the rules stale, and one goroutine
// compiles whenever they are. Every event used to compile on its informer's
// own goroutine, so a burst -- a Deployment's pods each changing several times
// on the way to Running -- compiled once per event, and four informers
// compiling at once could publish an older compilation after a newer one.
func compileCluster(ctx context.Context, kubeconfig, clusterCIDR string, resync time.Duration,
	rules, edge *ruleServer, views *nodeViews) error {

	config, err := clientcmd.BuildConfigFromFlags("", kubeconfig)
	if err != nil {
		klog.ErrorS(err, "Failed to read kubeconfig")
		return err
	}
	client, err := kubernetes.NewForConfig(config)
	if err != nil {
		klog.ErrorS(err, "Failed to build client")
		return err
	}
	compiler := &compiler{clusterCIDR: clusterCIDR}
	factory := informers.NewSharedInformerFactory(client, resync)
	compiler.policies = factory.Networking().V1().NetworkPolicies().Lister()
	compiler.pods = factory.Core().V1().Pods().Lister()
	compiler.namespaces = factory.Core().V1().Namespaces().Lister()
	compiler.nodes = factory.Core().V1().Nodes().Lister()

	stale := make(chan struct{}, 1)
	mark := func() {
		select {
		case stale <- struct{}{}:
		default:
		}
	}
	handler := cache.ResourceEventHandlerFuncs{
		AddFunc:    func(any) { mark() },
		UpdateFunc: func(any, any) { mark() },
		DeleteFunc: func(any) { mark() },
	}
	factory.Networking().V1().NetworkPolicies().Informer().AddEventHandler(handler)
	factory.Core().V1().Pods().Informer().AddEventHandler(handler)
	factory.Core().V1().Namespaces().Informer().AddEventHandler(handler)
	// Nodes matter because a pod's own node's address on the pod network is
	// exempt from ingress policy, and that address comes from its podCIDR.
	factory.Core().V1().Nodes().Informer().AddEventHandler(handler)

	rebuild := func() {
		r, err := compiler.compile()
		if err != nil {
			klog.ErrorS(err, "Failed to compile policies; the last rules stay in force")
			return
		}
		rules.publish(r.rules(nil))
		edge.publish(string(r.edge(nil)))
		views.publish(r)
	}
	factory.Start(ctx.Done())
	factory.WaitForCacheSync(ctx.Done())
	rebuild()
	go func() {
		for range stale {
			rebuild()
		}
	}()
	return nil
}
