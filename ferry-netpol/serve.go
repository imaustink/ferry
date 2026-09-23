package main

// What ferry-netpol hands out, and to whom.
//
// This Mac's own ferry-cri and ferry-proxy ask a unix socket, and get the
// whole cluster's rules: every node on this Mac is this Mac's.
//
// Another Mac cannot reach that socket, and used to run a ferry-netpol of its
// own -- as its node, which meant granting every kubelet in the cluster a read
// of every pod, namespace and node, because a policy selects peers anywhere.
// The Node authorizer allows a kubelet its own pods and nothing wider, and that
// grant was the widest thing a node could do. So the compiling happens only
// here, where it already happens with the cluster's own credentials, and the
// other Macs ask for the result over TLS.
//
// They present their kubelet's client certificate, and what is served is
// scoped to the node that certificate names: its own pods' rules and its own
// pods' edge. What a node learns that it could not have asked the API server
// for is the addresses its own pods' policies admit -- which it has to have to
// enforce them, and which is less than the pod specs, labels and namespaces
// the old grant handed over.

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/imaustink/ferry/nodeauth"
	"k8s.io/klog/v2"
)

// How long a caller that already has the current rules is held for.
var hold = 25 * time.Second // a variable for the tests

// ruleServer hands out the current rules and holds a caller that already has
// them until they change, the same bargain ferry-proxyd offers for Services.
type ruleServer struct {
	contentType string
	hold        time.Duration

	mu         sync.RWMutex
	rules      string
	ready      bool // something has been published
	generation uint64
	changed    chan struct{}
}

// newRuleServer starts its generations at the clock rather than at zero. A
// caller keeps the generation it last saw across a restart of this process,
// and one that counted from zero again would hold that caller until its
// timeout -- 25 seconds of rules nobody was given -- because the new rules'
// generation is not newer than what it already has.
func newRuleServer(contentType string) *ruleServer {
	return &ruleServer{contentType: contentType, hold: hold, changed: make(chan struct{}),
		generation: uint64(time.Now().UnixMicro())}
}

func (s *ruleServer) publish(rules string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ready && rules == s.rules {
		return
	}
	s.rules = rules
	s.ready = true
	s.generation++
	close(s.changed)
	s.changed = make(chan struct{})
	klog.V(2).InfoS("Rendered policy rules", "type", s.contentType, "generation", s.generation, "bytes", len(rules))
}

func (s *ruleServer) current() (string, uint64, bool, chan struct{}) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.rules, s.generation, s.ready, s.changed
}

// serve answers with the current rules, or holds a caller that has them. It
// never answers with rules it has not been given: before the first publish a
// caller is held and then refused, so that nothing mistakes "not known yet"
// for "no policies", which would open every pod.
func (s *ruleServer) serve(w http.ResponseWriter, r *http.Request) {
	rules, generation, ready, changed := s.current()
	wait := !ready
	if after := r.URL.Query().Get("after"); after != "" {
		if want, err := strconv.ParseUint(after, 10, 64); err == nil && generation <= want {
			wait = true
		}
	}
	if wait {
		timeout := time.NewTimer(s.hold)
		defer timeout.Stop()
		select {
		case <-changed:
			rules, generation, ready, _ = s.current()
		case <-timeout.C:
		case <-r.Context().Done():
			return
		}
	}
	if !ready {
		http.Error(w, "no rules yet", http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("X-Ferry-Generation", strconv.FormatUint(generation, 10))
	w.Header().Set("Content-Type", s.contentType)
	fmt.Fprint(w, rules)
}

// nodeViews is what the peer port serves: each node its own pods' part of the
// compilation, with generations of its own, so a node is woken only when its
// part changes and not by every pod that starts anywhere in the cluster.
type nodeViews struct {
	mu    sync.Mutex
	last  rendered
	have  bool
	nodes map[string]*nodeView
}

type nodeView struct{ rules, edge *ruleServer }

func newNodeViews() *nodeViews { return &nodeViews{nodes: map[string]*nodeView{}} }

func only(node string) func(string) bool { return func(n string) bool { return n == node } }

func (v *nodeViews) publish(r rendered) {
	v.mu.Lock()
	defer v.mu.Unlock()
	v.last, v.have = r, true
	for name, view := range v.nodes {
		view.rules.publish(r.rules(only(name)))
		view.edge.publish(string(r.edge(only(name))))
	}
}

// view is a node's, made the first time that node asks. Only nodes that ask
// are rendered for, which on a cluster of one Mac is none.
func (v *nodeViews) view(name string) *nodeView {
	v.mu.Lock()
	defer v.mu.Unlock()
	view, ok := v.nodes[name]
	if !ok {
		view = &nodeView{newRuleServer("text/plain"), newRuleServer("application/json")}
		if v.have {
			view.rules.publish(v.last.rules(only(name)))
			view.edge.publish(string(v.last.edge(only(name))))
		}
		v.nodes[name] = view
	}
	return view
}

// callerNode is the node a request's client certificate names. The chain was
// verified during the handshake (peerTLS); this only reads the name back out.
func callerNode(r *http.Request) (string, error) {
	if r.TLS == nil || len(r.TLS.PeerCertificates) == 0 {
		return "", fmt.Errorf("no client certificate")
	}
	return nodeauth.NameOf(r.TLS.PeerCertificates[0])
}

func (v *nodeViews) handler() http.Handler {
	scoped := func(pick func(*nodeView) *ruleServer) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			node, err := callerNode(r)
			if err != nil {
				http.Error(w, err.Error(), http.StatusForbidden)
				return
			}
			pick(v.view(node)).serve(w, r)
		}
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /rules", scoped(func(n *nodeView) *ruleServer { return n.rules }))
	mux.HandleFunc("GET /edge", scoped(func(n *nodeView) *ruleServer { return n.edge }))
	return mux
}

// peerTLS is the peer port's side of the handshake. It presents the API
// server's own serving certificate -- this process runs beside the API server,
// and a joined Mac already trusts that certificate for that address, so it
// can check it is talking to the control plane and not to any node that holds
// a cluster certificate. And it accepts only a kubelet client certificate
// signed by the cluster CA (nodeauth.Node).
func peerTLS(certFile, keyFile, caFile string) (*tls.Config, error) {
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, err
	}
	caPEM, err := os.ReadFile(caFile)
	if err != nil {
		return nil, err
	}
	roots, err := nodeauth.Pool(caPEM)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", caFile, err)
	}
	return &tls.Config{
		MinVersion:   tls.VersionTLS12,
		Certificates: []tls.Certificate{cert},
		ClientAuth:   tls.RequireAnyClientCert,
		VerifyPeerCertificate: func(raw [][]byte, _ [][]*x509.Certificate) error {
			_, err := nodeauth.Node(raw, roots, x509.ExtKeyUsageClientAuth)
			return err
		},
	}, nil
}
