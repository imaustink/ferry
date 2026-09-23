package main

// UDP, on the outside edge of a Service.
//
// The in-pod rules never needed this: kube-proxy renders UDP the same as TCP and
// a pod's own kernel forwards it, which is why UDP ClusterIPs worked before
// anyone tried them. The host side did need it -- a node port is a listener on
// the Mac, and a TCP listener does not carry DNS.
//
// UDP has no connections, so "which reply belongs to whom" has to be kept here:
// each client address gets a socket to the backend, and whatever comes back on
// it goes to that client. Sessions expire, because nothing closes them.
//
// A listener narrowed to some addresses (see newServiceProxy) is a wildcard
// socket, which UDP cannot filter at accept time because there is no accept.
// So each datagram says where it was sent, and the reply goes out from that
// same address -- a client that asked 192.168.1.20 must hear back from it, not
// from whichever address the route would have picked.

import (
	"net"
	"net/netip"
	"sync"
	"time"

	"golang.org/x/net/ipv4"
	"k8s.io/klog/v2"
)

const udpSessionIdle = 2 * time.Minute

type udpProxy struct {
	key      string
	listen   string
	conn     *net.UDPConn
	narrowed *ipv4.PacketConn // set when only is: carries each datagram's destination
	only     localAddresses
	backends *serviceProxy // reuses the same backend list and round-robin

	mu       sync.Mutex
	sessions map[string]*udpSession
	closed   bool
}

type udpSession struct {
	out   *net.UDPConn
	seen  time.Time
	local net.IP // where the client sent to, and so where replies come from
}

func newUDPProxy(key, address string, port int32, backends *serviceProxy, only localAddresses) (*udpProxy, error) {
	network := "udp"
	if only != nil {
		network = "udp4" // IP_RECVDSTADDR is an IPv4 option
	}
	addr, err := net.ResolveUDPAddr(network, net.JoinHostPort(address, itoa(port)))
	if err != nil {
		return nil, err
	}
	conn, err := net.ListenUDP(network, addr)
	if err != nil {
		return nil, err
	}
	p := &udpProxy{
		key: key, listen: conn.LocalAddr().String(), conn: conn, only: only,
		backends: backends, sessions: map[string]*udpSession{},
	}
	if only != nil {
		p.narrowed = ipv4.NewPacketConn(conn)
		if err := p.narrowed.SetControlMessage(ipv4.FlagDst, true); err != nil {
			conn.Close()
			return nil, err
		}
	}
	go p.serve()
	go p.expire()
	return p, nil
}

func (p *udpProxy) serve() {
	buffer := make([]byte, 64*1024)
	for {
		var n int
		var from *net.UDPAddr
		var local net.IP
		if p.narrowed != nil {
			count, cm, source, err := p.narrowed.ReadFrom(buffer)
			if err != nil {
				return
			}
			if cm == nil || !p.only.hasIP(netipFrom(cm.Dst)) {
				continue // sent to an address this Service is not published on
			}
			n, from, local = count, source.(*net.UDPAddr), cm.Dst
		} else {
			count, source, err := p.conn.ReadFromUDP(buffer)
			if err != nil {
				return
			}
			n, from = count, source
		}
		session, err := p.sessionFor(from, local)
		if err != nil {
			continue
		}
		if _, err := session.out.Write(buffer[:n]); err != nil {
			klog.V(2).InfoS("Dropped a datagram", "service", p.key, "err", err)
		}
	}
}

// sessionFor gives each client its own socket to a backend, so replies can be
// told apart. Choosing the backend once per client also keeps a conversation
// with one of them rather than spreading it across several -- and means policy
// is checked once per conversation, not once per datagram.
func (p *udpProxy) sessionFor(client *net.UDPAddr, local net.IP) (*udpSession, error) {
	key := client.String()
	p.mu.Lock()
	defer p.mu.Unlock()
	if session, ok := p.sessions[key]; ok {
		session.seen = time.Now()
		return session, nil
	}
	backend, ok := p.backends.pick()
	if !ok {
		return nil, errNoBackends
	}
	if !admits(backend.pod, "udp", clientAddr(client), backend.hostPort) {
		klog.V(2).InfoS("Refused by NetworkPolicy", "service", p.key,
			"client", key, "endpoint", backend.address)
		return nil, errRefused
	}
	addr, err := net.ResolveUDPAddr("udp", backend.address)
	if err != nil {
		return nil, err
	}
	out, err := net.DialUDP("udp", nil, addr)
	if err != nil {
		return nil, err
	}
	session := &udpSession{out: out, seen: time.Now(), local: local}
	p.sessions[key] = session
	go p.relay(client, session)
	return session, nil
}

func (p *udpProxy) relay(client *net.UDPAddr, session *udpSession) {
	buffer := make([]byte, 64*1024)
	var reply *ipv4.ControlMessage
	if session.local != nil {
		reply = &ipv4.ControlMessage{Src: session.local}
	}
	for {
		_ = session.out.SetReadDeadline(time.Now().Add(udpSessionIdle))
		n, err := session.out.Read(buffer)
		if err != nil {
			return
		}
		if reply != nil {
			_, err = p.narrowed.WriteTo(buffer[:n], reply, client)
		} else {
			_, err = p.conn.WriteToUDP(buffer[:n], client)
		}
		if err != nil {
			return
		}
	}
}

func (p *udpProxy) expire() {
	for range time.Tick(30 * time.Second) {
		p.mu.Lock()
		if p.closed {
			p.mu.Unlock()
			return
		}
		for key, session := range p.sessions {
			if time.Since(session.seen) > udpSessionIdle {
				session.out.Close()
				delete(p.sessions, key)
			}
		}
		p.mu.Unlock()
	}
}

func (p *udpProxy) close() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.closed = true
	p.conn.Close()
	for key, session := range p.sessions {
		session.out.Close()
		delete(p.sessions, key)
	}
}

func netipFrom(ip net.IP) netip.Addr {
	a, _ := netip.AddrFromSlice(ip)
	return a.Unmap()
}
