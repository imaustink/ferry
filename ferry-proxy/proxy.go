package main

// A userspace stand-in for kube-proxy.
//
// kube-proxy programs the node's firewall to DNAT a ClusterIP to a backend pod.
// There is no node here -- pods are virtual machines and the Mac is the host --
// and macOS has no nftables, so instead each ClusterIP is bound locally and a
// listener forwards to a ready endpoint.
//
// The trade-off is that Service traffic hairpins through the host rather than
// going pod to pod directly. On a local cluster with a measured host round trip
// of well under a millisecond that is a latency question, not a correctness
// one. Programming rules inside each pod's own kernel would avoid the hop and
// is the better end state; see docs/SERVICES.md.

import (
	"io"
	"net"
	"strconv"
	"sync"
	"sync/atomic"

	"k8s.io/klog/v2"
)

type backend struct {
	address string
}

// serviceProxy listens on one address and port and forwards to a Service's
// ready endpoints. The address is a ClusterIP, a node port on every interface,
// or the Mac's own address standing in for a load balancer -- the forwarding is
// the same in all three cases, because a pod is reachable from the Mac either
// way.
type serviceProxy struct {
	key       string
	listen    string
	listener  net.Listener
	backends  atomic.Pointer[[]backend]
	next      atomic.Uint64
	closeOnce sync.Once
}

func newServiceProxy(key, address string, port int32) (*serviceProxy, error) {
	listen := net.JoinHostPort(address, strconv.Itoa(int(port)))
	listener, err := net.Listen("tcp", listen)
	if err != nil {
		return nil, err
	}
	p := &serviceProxy{key: key, listen: listen, listener: listener}
	empty := []backend{}
	p.backends.Store(&empty)
	go p.serve()
	return p, nil
}

func (p *serviceProxy) setBackends(b []backend) {
	p.backends.Store(&b)
}

// pick returns the next backend round-robin. Session affinity is not
// implemented; every connection is balanced independently.
func (p *serviceProxy) pick() (backend, bool) {
	b := *p.backends.Load()
	if len(b) == 0 {
		return backend{}, false
	}
	i := p.next.Add(1) - 1
	return b[i%uint64(len(b))], true
}

func (p *serviceProxy) serve() {
	for {
		conn, err := p.listener.Accept()
		if err != nil {
			return // listener closed
		}
		go p.handle(conn)
	}
}

func (p *serviceProxy) handle(client net.Conn) {
	defer client.Close()
	target, ok := p.pick()
	if !ok {
		// No ready endpoints. Closing immediately is what a Service with no
		// backends should look like: connection refused rather than a hang.
		klog.V(4).InfoS("No endpoints for service", "service", p.key)
		return
	}
	upstream, err := net.Dial("tcp", target.address)
	if err != nil {
		klog.V(2).InfoS("Failed to reach endpoint", "service", p.key, "endpoint", target.address, "err", err)
		return
	}
	defer upstream.Close()

	done := make(chan struct{}, 2)
	go func() { io.Copy(upstream, client); done <- struct{}{} }()
	go func() { io.Copy(client, upstream); done <- struct{}{} }()
	<-done
}

func (p *serviceProxy) close() {
	p.closeOnce.Do(func() { p.listener.Close() })
}
