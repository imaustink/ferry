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
	"errors"
	"io"
	"net"
	"net/netip"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/klog/v2"
)

// backend is where a connection goes. pod is set when that is a pod on this
// Mac, which is what NetworkPolicy is checked against; a connection handed to
// another node's port leaves it unset, and that node checks it.
type backend struct {
	address  string
	pod      netip.AddrPort
	hostPort bool // address is a hostPort, which the pod maps to a container port
}

func podBackend(address string) backend {
	pod, _ := netip.ParseAddrPort(address)
	return backend{address: address, pod: pod}
}

var (
	errNoBackends = errors.New("no ready endpoints")
	errRefused    = errors.New("refused by NetworkPolicy")
)

func itoa(port int32) string { return strconv.Itoa(int(port)) }

// serviceProxy listens on one address and port and forwards to a Service's
// ready endpoints. The address is a ClusterIP, a node port on every interface,
// or the Mac's own address standing in for a load balancer -- the forwarding is
// the same in all three cases, because a pod is reachable from the Mac either
// way.
type serviceProxy struct {
	key       string
	listen    string
	listeners []net.Listener
	shared    bool           // the wildcard was taken, so each address is bound instead
	only      localAddresses // nil: every address the listener is bound to
	backends  atomic.Pointer[[]backend]
	next      atomic.Uint64
	closeOnce sync.Once
}

// newServiceProxy listens for a Service. TCP gets a listener and a goroutine per
// connection; UDP gets neither, because there are no connections -- the caller
// builds a udpProxy around this one for its backend list and picks.
//
// only narrows a wildcard listener to some of the Mac's addresses. That is how
// a port below 1024 is served without root: macOS lets anyone bind one on the
// wildcard address, and nobody bind one on a particular address.
//
// The wildcard can be taken where the addresses are not. macOS's AirPlay
// Receiver holds *:5000 and *:7000, and a particular address is still free to
// bind beside it -- the more specific listener wins the connection. So at 1024
// and above a wildcard that is in use falls back to each address on its own,
// which is what a LoadBalancer bound before this change, and what still works.
func newServiceProxy(key, address string, port int32, protocol corev1.Protocol, only localAddresses) (*serviceProxy, error) {
	listen := net.JoinHostPort(address, strconv.Itoa(int(port)))
	p := &serviceProxy{key: key, listen: listen, only: only}
	empty := []backend{}
	p.backends.Store(&empty)

	if protocol == corev1.ProtocolUDP {
		return p, nil
	}
	listener, err := net.Listen("tcp", listen)
	switch {
	case err == nil:
		p.listeners = []net.Listener{listener}
	case address == "" && only != nil && port >= 1024 && errors.Is(err, syscall.EADDRINUSE):
		for _, ip := range only {
			if l, e := net.Listen("tcp", net.JoinHostPort(ip.String(), strconv.Itoa(int(port)))); e == nil {
				p.listeners = append(p.listeners, l)
			}
		}
		if len(p.listeners) == 0 {
			return nil, err
		}
		p.shared = true
	default:
		return nil, err
	}
	for _, l := range p.listeners {
		go p.serve(l)
	}
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

func (p *serviceProxy) serve(listener net.Listener) {
	for {
		conn, err := listener.Accept()
		if err != nil {
			return // listener closed
		}
		if !p.only.has(conn.LocalAddr()) {
			// Somebody reached the wildcard at an address this Service is not
			// published on -- the vmnet gateway, say. Refuse, as a listener
			// bound to the right address alone would have.
			refuse(conn)
			continue
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
	if !admits(target.pod, "tcp", clientAddr(client.RemoteAddr()), target.hostPort) {
		klog.V(2).InfoS("Refused by NetworkPolicy", "service", p.key,
			"client", client.RemoteAddr().String(), "endpoint", target.address)
		refuse(client)
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
	p.closeOnce.Do(func() {
		for _, l := range p.listeners {
			l.Close()
		}
	})
}

// refuse closes a connection with a reset rather than a goodbye, so a client
// sees "connection refused" -- what a port nobody listens on looks like.
func refuse(conn net.Conn) {
	if tcp, ok := conn.(*net.TCPConn); ok {
		_ = tcp.SetLinger(0)
	}
	conn.Close()
}

// localAddresses is a set of the Mac's own addresses a listener answers on.
// nil is all of them.
type localAddresses []netip.Addr

func (l localAddresses) has(a net.Addr) bool {
	if l == nil {
		return true
	}
	return l.hasIP(clientAddr(a))
}

func (l localAddresses) hasIP(ip netip.Addr) bool {
	if l == nil {
		return true
	}
	ip = ip.Unmap()
	for _, want := range l {
		if want == ip {
			return true
		}
	}
	return false
}
