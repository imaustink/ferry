package main

// ferry-netpol on a Mac that joined: a follower of the control plane's.
//
// It compiles nothing and watches nothing. For each node this Mac runs it asks
// the control plane's peer port for that node's rules, presenting that node's
// own kubelet certificate, and serves the union on the same unix socket, in
// the same two forms, that ferry-cri and ferry-proxy already ask. Neither of
// them can tell the difference.
//
// It follows the same way they do: ask for something newer than the last
// generation and be held until there is some. So a policy change is one more
// held request answering on the way to a pod, not a poll interval.
//
// When the control plane cannot be reached -- asleep, off the network, or
// ferry-netpol there restarting -- nothing is published, so what was last
// received stays in force: in ferry-cri, which keeps each pod's rules until it
// is given different ones, in the pods' kernels, and at ferry-proxy's edge.
// This never publishes rules it did not receive. Before the first answer for
// every node there is nothing to serve, and callers are held and refused
// rather than told there are no policies.

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/imaustink/ferry/nodeauth"
	"k8s.io/klog/v2"
)

// upstream is the control plane's peer port, as one node.
type upstream struct {
	node   string
	base   string
	client *http.Client
}

// newUpstream reads a node's kubeconfig for the credentials to present and
// the CA to check the control plane with. The certificate is read again for
// every handshake, because the kubelet rotates it in place.
func newUpstream(kubeconfig, address string) (*upstream, error) {
	k, err := nodeauth.Read(kubeconfig)
	if err != nil {
		return nil, err
	}
	roots, err := nodeauth.Pool(k.CA)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", kubeconfig, err)
	}
	cert, _, err := nodeauth.Load(kubeconfig)
	if err != nil {
		return nil, err
	}
	node := kubeconfig
	if len(cert.Certificate) > 0 {
		if leaf, err := parseLeaf(cert); err == nil {
			if name, err := nodeauth.NameOf(leaf); err == nil {
				node = name
			}
		}
	}
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return nil, fmt.Errorf("upstream %q: %w", address, err)
	}
	config := &tls.Config{
		MinVersion: tls.VersionTLS12,
		RootCAs:    roots,
		// The address the kubelet reaches the API server at, which the API
		// server's certificate names; the peer port presents that certificate.
		ServerName: host,
		GetClientCertificate: func(*tls.CertificateRequestInfo) (*tls.Certificate, error) {
			cert, _, err := nodeauth.Load(kubeconfig)
			return &cert, err
		},
	}
	transport := &http.Transport{
		TLSClientConfig:     config,
		ForceAttemptHTTP2:   true, // both follows share one connection per node
		DialContext:         (&net.Dialer{Timeout: 3 * time.Second, KeepAlive: 15 * time.Second}).DialContext,
		TLSHandshakeTimeout: 5 * time.Second,
		// A control plane that went to sleep does not close anything, so a
		// held request would otherwise sit on a dead connection until its
		// timeout. A ping that goes unanswered ends it sooner.
		HTTP2:           &http.HTTP2Config{SendPingTimeout: 10 * time.Second, PingTimeout: 5 * time.Second},
		IdleConnTimeout: 90 * time.Second,
	}
	return &upstream{node: node, base: "https://" + address,
		client: &http.Client{Transport: transport, Timeout: hold + 15*time.Second}}, nil
}

// fetch asks for path newer than after. It returns after unchanged when it was
// held and nothing changed.
func (u *upstream) fetch(path string, after uint64) ([]byte, uint64, error) {
	resp, err := u.client.Get(u.base + path + "?after=" + strconv.FormatUint(after, 10))
	if err != nil {
		return nil, after, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64<<20))
	if err != nil {
		return nil, after, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, after, fmt.Errorf("%s: %s", resp.Status, strings.TrimSpace(string(body)))
	}
	generation, err := strconv.ParseUint(resp.Header.Get("X-Ferry-Generation"), 10, 64)
	if err != nil {
		return nil, after, fmt.Errorf("no generation in the answer")
	}
	return body, generation, nil
}

// follower merges what each node's upstream says and serves it locally.
type follower struct {
	upstreams   []*upstream
	rules, edge *ruleServer

	mu     sync.Mutex
	pods   []string // per upstream; "" until received
	edges  []*edgeDocument
	gotPod []bool
}

func newFollower(upstreams []*upstream, rules, edge *ruleServer) *follower {
	return &follower{upstreams: upstreams, rules: rules, edge: edge,
		pods: make([]string, len(upstreams)), edges: make([]*edgeDocument, len(upstreams)),
		gotPod: make([]bool, len(upstreams))}
}

func (f *follower) start() {
	for i, u := range f.upstreams {
		go f.follow(u, "/rules", func(body []byte) error { return f.setRules(i, string(body)) })
		go f.follow(u, "/edge", func(body []byte) error { return f.setEdge(i, body) })
	}
}

func (f *follower) follow(u *upstream, path string, set func([]byte) error) {
	var generation uint64
	backoff, down := minBackoff, false
	var since time.Time
	for {
		body, next, err := u.fetch(path, generation)
		if err == nil && next != generation {
			err = set(body)
		}
		if err != nil {
			if !down {
				down, since = true, time.Now()
				klog.InfoS("Control plane's ferry-netpol not answering; the last rules received stay in force",
					"node", u.node, "path", path, "err", err)
			}
			time.Sleep(backoff)
			backoff = min(backoff*2, maxBackoff)
			continue
		}
		if down {
			down = false
			klog.InfoS("Control plane's ferry-netpol answering again", "node", u.node, "path", path,
				"after", time.Since(since).Round(time.Millisecond))
		}
		backoff = minBackoff
		if next != generation {
			klog.V(2).InfoS("Received policy rules", "node", u.node, "path", path, "generation", next, "bytes", len(body))
		}
		generation = next
	}
}

const (
	minBackoff = 250 * time.Millisecond
	maxBackoff = 5 * time.Second
)

func (f *follower) setRules(i int, rules string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.pods[i], f.gotPod[i] = rules, true
	f.publishLocked()
	return nil
}

func (f *follower) setEdge(i int, body []byte) error {
	var document edgeDocument
	if err := json.Unmarshal(body, &document); err != nil || document.Pods == nil {
		return fmt.Errorf("edge document does not parse: %v", err)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.edges[i] = &document
	f.publishLocked()
	return nil
}

// publishLocked publishes only once every node has been heard from. A merge
// with a node missing would tell ferry-proxy that node's pods are isolated by
// nothing, and ferry-cri that they have no rules.
func (f *follower) publishLocked() {
	var rules strings.Builder
	merged := edgeDocument{Pods: map[string]edgePod{}}
	for i := range f.upstreams {
		if !f.gotPod[i] || f.edges[i] == nil {
			return
		}
		rules.WriteString(f.pods[i])
		for address, pod := range f.edges[i].Pods {
			merged.Pods[address] = pod
		}
	}
	document, _ := json.Marshal(merged)
	f.rules.publish(rules.String())
	f.edge.publish(string(document))
}

func parseLeaf(cert tls.Certificate) (*x509.Certificate, error) {
	return x509.ParseCertificate(cert.Certificate[0])
}
