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

import (
	"net"
	"sync"
	"time"

	"k8s.io/klog/v2"
)

const udpSessionIdle = 2 * time.Minute

type udpProxy struct {
	key      string
	listen   string
	conn     *net.UDPConn
	backends *serviceProxy // reuses the same backend list and round-robin

	mu       sync.Mutex
	sessions map[string]*udpSession
	closed   bool
}

type udpSession struct {
	out  *net.UDPConn
	seen time.Time
}

func newUDPProxy(key, address string, port int32, backends *serviceProxy) (*udpProxy, error) {
	addr, err := net.ResolveUDPAddr("udp", net.JoinHostPort(address, itoa(port)))
	if err != nil {
		return nil, err
	}
	conn, err := net.ListenUDP("udp", addr)
	if err != nil {
		return nil, err
	}
	p := &udpProxy{
		key: key, listen: conn.LocalAddr().String(), conn: conn,
		backends: backends, sessions: map[string]*udpSession{},
	}
	go p.serve()
	go p.expire()
	return p, nil
}

func (p *udpProxy) serve() {
	buffer := make([]byte, 64*1024)
	for {
		n, from, err := p.conn.ReadFromUDP(buffer)
		if err != nil {
			return
		}
		session, err := p.sessionFor(from)
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
// with one of them rather than spreading it across several.
func (p *udpProxy) sessionFor(client *net.UDPAddr) (*udpSession, error) {
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
	addr, err := net.ResolveUDPAddr("udp", backend.address)
	if err != nil {
		return nil, err
	}
	out, err := net.DialUDP("udp", nil, addr)
	if err != nil {
		return nil, err
	}
	session := &udpSession{out: out, seen: time.Now()}
	p.sessions[key] = session
	go p.relay(client, session)
	return session, nil
}

func (p *udpProxy) relay(client *net.UDPAddr, session *udpSession) {
	buffer := make([]byte, 64*1024)
	for {
		_ = session.out.SetReadDeadline(time.Now().Add(udpSessionIdle))
		n, err := session.out.Read(buffer)
		if err != nil {
			return
		}
		if _, err := p.conn.WriteToUDP(buffer[:n], client); err != nil {
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
