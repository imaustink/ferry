//go:build darwin

// ferry-proxyd renders Service rules on macOS.
//
// kube-proxy cannot run on a Mac: it programs netfilter, and macOS has none.
// But ferry's pods each have a Linux kernel, so the rules are wanted -- just
// not here. This runs kube-proxy's own rule generation against a rendering
// backend and serves the ruleset it would have applied; ferry-cri loads it into
// each pod, where a real kernel exists.
//
// Everything that makes Service behaviour correct therefore comes from upstream:
// reject rules for Services with no endpoints, hairpin masquerade, rejection of
// traffic to valid ClusterIPs on wrong ports, endpoint selection and session
// affinity. None of it is reimplemented here.
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

	v1 "k8s.io/api/core/v1"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/klog/v2"
	"k8s.io/kubernetes/pkg/proxy/config"
	"k8s.io/kubernetes/pkg/proxy/nftables"
	proxyutil "k8s.io/kubernetes/pkg/proxy/util"
)

// How long a client waiting for a new ruleset is left hanging before being sent
// away with what there is. Only needs to be short enough that a dead client or
// a restarted ferry-cri is noticed in reasonable time.
const longPollTimeout = 25 * time.Second

func main() {
	kubeconfig := flag.String("kubeconfig", "", "kubeconfig with cluster-wide read access")
	socketPath := flag.String("socket", "/tmp/ferry-proxyd.sock", "socket to serve the ruleset on")
	nodeName := flag.String("node-name", "ferry-mac", "node name to generate rules for")
	nodeIPText := flag.String("node-ip", "", "the pod network gateway")
	syncPeriod := flag.Duration("sync-period", 30*time.Second, "full resync period")
	klog.InitFlags(nil)
	flag.Parse()

	if *kubeconfig == "" || *nodeIPText == "" {
		fmt.Fprintln(os.Stderr, "--kubeconfig and --node-ip are required")
		os.Exit(2)
	}
	nodeIP := net.ParseIP(*nodeIPText)
	if nodeIP == nil {
		fmt.Fprintf(os.Stderr, "bad --node-ip %q\n", *nodeIPText)
		os.Exit(2)
	}

	restConfig, err := clientcmd.BuildConfigFromFlags("", *kubeconfig)
	if err != nil {
		fmt.Fprintf(os.Stderr, "read kubeconfig: %v\n", err)
		os.Exit(1)
	}
	client, err := kubernetes.NewForConfig(restConfig)
	if err != nil {
		fmt.Fprintf(os.Stderr, "build client: %v\n", err)
		os.Exit(1)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Traffic policies distinguish local from remote endpoints by node. Every
	// pod here is its own machine, so nothing is "local" in that sense and the
	// no-op detector is the honest answer.
	proxier, err := nftables.NewProxier(ctx,
		v1.IPv4Protocol,
		*syncPeriod,
		time.Second,
		false, // masqueradeAll: only hairpins need it, which kube-proxy marks itself
		14,    // masqueradeBit, kube-proxy's default
		proxyutil.NewNoOpLocalDetector(),
		*nodeName,
		nodeIP,
		nil, nil, nil,
		false,
	)
	if err != nil {
		fmt.Fprintf(os.Stderr, "create proxier: %v\n", err)
		os.Exit(1)
	}

	factory := informers.NewSharedInformerFactory(client, *syncPeriod)
	serviceConfig := config.NewServiceConfig(ctx, factory.Core().V1().Services(), *syncPeriod)
	serviceConfig.RegisterEventHandler(proxier)
	go serviceConfig.Run(ctx.Done())

	endpointsConfig := config.NewEndpointSliceConfig(ctx, factory.Discovery().V1().EndpointSlices(), *syncPeriod)
	endpointsConfig.RegisterEventHandler(proxier)
	go endpointsConfig.Run(ctx.Done())

	factory.Start(ctx.Done())

	go proxier.SyncLoop()

	server := newRulesetServer()
	go server.track(ctx)

	_ = os.Remove(*socketPath)
	listener, err := net.Listen("unix", *socketPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "listen %s: %v\n", *socketPath, err)
		os.Exit(1)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/ruleset", server.serve)
	go http.Serve(listener, mux)

	fmt.Printf("==> ferry-proxyd\n    ruleset   unix://%s\n    node      %s (%s)\n    serving\n",
		*socketPath, *nodeName, nodeIP)

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop
	_ = os.Remove(*socketPath)
}

// replaceTable makes a rendered ruleset replace what a pod already has rather
// than pile onto it.
//
// knftables' fake backend accumulates state and Dump()s it as a script that
// builds the table from nothing -- every line an "add". Against a real kernel
// kube-proxy never needs more, because it sends transactions and says explicitly
// what to remove. ferry does not: it hands the whole dump to a pod that already
// has the table, so anything that should have gone away simply stays. A Service
// that briefly had no endpoints keeps the reject rule ahead of the good one, and
// that pod cannot reach it again for as long as it lives -- which is why Services
// worked when a pod booted and rotted as the cluster changed around it.
//
// "add table" then "delete table" is the nftables idiom for replacing a table:
// the add makes the delete safe when the table is not there yet, and nft applies
// the file as one transaction, so no pod is ever left without rules in between.
func replaceTable(rendered string) string {
	if rendered == "" {
		return rendered
	}
	const table = "kube-proxy"
	return "add table ip " + table + "\n" +
		"delete table ip " + table + "\n" +
		rendered
}

// rulesetServer holds the most recently rendered ruleset and hands it out. The
// generation only advances when the text actually changes, so a caller that
// names the generation it already has can be left waiting until there is
// genuinely something new -- which is what makes a Service reach the pods as
// soon as it is rendered rather than on the next tick of a poll.
type rulesetServer struct {
	mu         sync.RWMutex
	ruleset    string
	generation uint64
	// changed is closed and replaced on every bump. A reader takes it under the
	// lock and then waits on it, so it cannot miss a change that lands between
	// reading the generation and starting to wait.
	changed chan struct{}
}

func newRulesetServer() *rulesetServer {
	return &rulesetServer{changed: make(chan struct{})}
}

func (s *rulesetServer) current() (string, uint64, chan struct{}) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.ruleset, s.generation, s.changed
}

func (s *rulesetServer) publish(rendered string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if rendered == "" || rendered == s.ruleset {
		return
	}
	s.ruleset = rendered
	s.generation++
	close(s.changed)
	s.changed = make(chan struct{})
	klog.V(2).InfoS("Rendered a new ruleset", "generation", s.generation, "bytes", len(rendered))
}

// track re-renders whenever the proxier has applied a transaction. The proxier
// says so directly, so there is no polling here and no render that turns out to
// have been unnecessary.
func (s *rulesetServer) track(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-nftables.FerryApplied:
			if nftables.FerryRendered != nil {
				s.publish(replaceTable(nftables.FerryRendered.Dump()))
			}
		}
	}
}

// serve answers GET /ruleset, optionally with ?after=<generation>. Without it,
// whatever stands now. With it, the caller is held until there is something
// newer than the generation it names -- or until the timeout, after which it
// gets the current ruleset and asks again.
func (s *rulesetServer) serve(w http.ResponseWriter, r *http.Request) {
	ruleset, generation, changed := s.current()

	if after := r.URL.Query().Get("after"); after != "" {
		if want, err := strconv.ParseUint(after, 10, 64); err == nil && generation <= want {
			timeout := time.NewTimer(longPollTimeout)
			defer timeout.Stop()
			select {
			case <-changed:
				ruleset, generation, _ = s.current()
			case <-timeout.C:
			case <-r.Context().Done():
				return
			}
		}
	}

	if ruleset == "" {
		http.Error(w, "no ruleset rendered yet", http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("X-Ferry-Generation", strconv.FormatUint(generation, 10))
	w.Header().Set("Content-Type", "text/plain")
	fmt.Fprint(w, ruleset)
}
