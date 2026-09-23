// ferry-handover holds the API server's port while one API server replaces
// another, so that nothing connecting in the meantime is refused.
//
// The API server listens on [::]:P, a dual-stack wildcard. This binds every
// IPv4 address the Mac has on the same port -- 127.0.0.1:P, the LAN address,
// the pod gateway -- which macOS always prefers over a wildcard listener, and
// is allowed to coexist with it because it is a different address family. Every
// client reaches the API server over IPv4: kubeconfigs name 127.0.0.1, kubelets
// on other Macs and pods through 10.96.0.1 arrive at the LAN address. So while
// this runs, every new connection lands here instead, and is spliced through to
// [::1]:P, which only the API server listens on.
//
// While there is no API server -- the old one has closed its listener and the
// new one has not yet bound -- the dial to [::1]:P is refused, and this keeps
// retrying rather than passing the refusal on. The client sees a connection
// that takes a moment to answer, not one that was refused.
//
// [::1] is left alone on purpose. It is the address an API server's loopback
// client dials to reach itself during its own start, and it has to reach
// itself: see control-plane/up.sh.
//
// Signals:
//
//	SIGUSR1  hold: stop dialling the API server, and keep what arrives waiting.
//	         Sent as the old one is told to stop, so that nothing reaches the
//	         new one before it is ready -- it answers from the moment it binds,
//	         but for a second or so /readyz says 500 and its authorizers are
//	         still filling.
//	SIGUSR2  release: dial again, and let everything waiting through.
//	SIGTERM  stop accepting, which hands new connections straight back to the
//	         API server. A spliced connection is then closed the first time it
//	         has been quiet for -quiet, which is between requests rather than
//	         in the middle of one. One that is never that quiet -- a client
//	         asking twenty times a second -- is closed after -drain at the
//	         first gap a tenth as long, and after twice -drain regardless.
//
//	ferry-handover --port 6443 [--hold 30s] [--quiet 250ms] [--drain 30s]
package main

import (
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

func main() {
	port := flag.Int("port", 0, "the API server's port")
	upstream := flag.String("upstream", "", "where to splice to (default [::1]:port)")
	hold := flag.Duration("hold", 30*time.Second, "how long to keep retrying a refused dial before giving up on a connection")
	quiet := flag.Duration("quiet", 250*time.Millisecond, "after SIGTERM, close a spliced connection once it has carried nothing for this long")
	drain := flag.Duration("drain", 30*time.Second, "after SIGTERM, close whatever is still spliced after this long")
	flag.Parse()
	if *port == 0 {
		fmt.Fprintln(os.Stderr, "--port is required")
		os.Exit(2)
	}
	if *upstream == "" {
		*upstream = fmt.Sprintf("[::1]:%d", *port)
	}

	addrs, err := ipv4Addrs()
	if err != nil {
		fmt.Fprintln(os.Stderr, "listing addresses:", err)
		os.Exit(1)
	}
	var listeners []net.Listener
	for _, a := range addrs {
		l, err := net.Listen("tcp4", net.JoinHostPort(a, fmt.Sprint(*port)))
		if err != nil {
			// An address that cannot be bound is one this does not cover, not a
			// reason to cover none of them. 127.0.0.1 is the exception: it is
			// where every kubeconfig on this Mac points.
			if a == "127.0.0.1" {
				fmt.Fprintln(os.Stderr, "binding 127.0.0.1:", err)
				os.Exit(1)
			}
			fmt.Fprintf(os.Stderr, "skipping %s: %v\n", a, err)
			continue
		}
		listeners = append(listeners, l)
	}

	var (
		wg       sync.WaitGroup
		mu       sync.Mutex
		live     = map[*pair]struct{}{}
		gate     = newGate()
		accepted atomic.Int64
		held     atomic.Int64 // connections that waited for an API server
		dropped  atomic.Int64 // ones that never found one within -hold
		maxWait  atomic.Int64 // longest wait for an API server, ms
		quietly  atomic.Int64 // spliced connections closed between requests
		forced   atomic.Int64 // ones still busy at -drain
	)

	splice := func(client net.Conn) {
		defer wg.Done()
		defer client.Close()
		start := time.Now()
		waited := false
		var up net.Conn
		for {
			if !gate.open(*hold - time.Since(start)) {
				waited = true
			}
			var err error
			if up, err = net.DialTimeout("tcp", *upstream, time.Second); err == nil {
				break
			}
			waited = true
			if time.Since(start) > *hold {
				dropped.Add(1)
				return
			}
			time.Sleep(10 * time.Millisecond)
		}
		if waited {
			held.Add(1)
		}
		if ms := time.Since(start).Milliseconds(); ms > maxWait.Load() {
			maxWait.Store(ms)
		}
		defer up.Close()
		p := &pair{a: client, b: up}
		p.touch()
		mu.Lock()
		live[p] = struct{}{}
		mu.Unlock()
		defer func() { mu.Lock(); delete(live, p); mu.Unlock() }()
		done := make(chan struct{}, 2)
		go func() { p.copy(up, client); closeWrite(up); done <- struct{}{} }()
		go func() { p.copy(client, up); closeWrite(client); done <- struct{}{} }()
		<-done
		<-done
	}

	for _, l := range listeners {
		go func(l net.Listener) {
			for {
				c, err := l.Accept()
				if err != nil {
					if errors.Is(err, net.ErrClosed) {
						return
					}
					continue
				}
				accepted.Add(1)
				wg.Add(1)
				go splice(c)
			}
		}(l)
	}
	// One line when every address is bound, which is what the caller waits for.
	fmt.Printf("bridging %d addresses on port %d to %s\n", len(listeners), *port, *upstream)

	sigs := make(chan os.Signal, 4)
	signal.Notify(sigs, syscall.SIGTERM, os.Interrupt, syscall.SIGUSR1, syscall.SIGUSR2)
	for sig := range sigs {
		if sig == syscall.SIGUSR1 {
			gate.close()
			continue
		}
		if sig == syscall.SIGUSR2 {
			gate.release()
			continue
		}
		break
	}
	gate.release()
	for _, l := range listeners {
		l.Close()
	}
	finished := make(chan struct{})
	go func() { wg.Wait(); close(finished) }()
	deadline := time.Now().Add(*drain)
	hard := deadline.Add(*drain)
	tick := time.NewTicker(*quiet / 25)
	defer tick.Stop()
	for waiting := true; waiting; {
		select {
		case <-finished:
			waiting = false
		case now := <-tick.C:
			mu.Lock()
			for p := range live {
				gap := *quiet
				if now.After(deadline) {
					gap = *quiet / 10
				}
				if now.After(hard) {
					if p.close() {
						forced.Add(1)
					}
				} else if p.idle() > gap && p.close() {
					quietly.Add(1)
				}
			}
			mu.Unlock()
		}
	}
	fmt.Printf("accepted %d, %d waited for an API server (longest %dms), %d never found one; "+
		"after letting go, %d closed between requests and %d still busy at %v\n",
		accepted.Load(), held.Load(), maxWait.Load(), dropped.Load(), quietly.Load(), forced.Load(), 2**drain)
}

// A spliced connection, and when it last carried a byte in either direction.
type pair struct {
	a, b net.Conn
	last atomic.Int64
	once sync.Once
}

func (p *pair) touch()              { p.last.Store(time.Now().UnixNano()) }
func (p *pair) idle() time.Duration { return time.Duration(time.Now().UnixNano() - p.last.Load()) }

// Reports whether this call was the one that closed it.
func (p *pair) close() (first bool) {
	p.once.Do(func() { first = true; p.a.Close(); p.b.Close() })
	return first
}

func (p *pair) copy(dst, src net.Conn) {
	buf := make([]byte, 32<<10)
	for {
		n, err := src.Read(buf)
		if n > 0 {
			p.touch()
			if _, werr := dst.Write(buf[:n]); werr != nil {
				return
			}
			p.touch()
		}
		if err != nil {
			return
		}
	}
}

// Whether new connections may dial the API server yet.
type gate struct {
	mu   sync.Mutex
	shut bool
	ch   chan struct{}
}

func newGate() *gate { return &gate{} }

func (g *gate) close() {
	g.mu.Lock()
	if !g.shut {
		g.shut, g.ch = true, make(chan struct{})
	}
	g.mu.Unlock()
}

func (g *gate) release() {
	g.mu.Lock()
	if g.shut {
		g.shut = false
		close(g.ch)
	}
	g.mu.Unlock()
}

// Reports whether the gate was open without waiting; otherwise waits for it,
// or for d.
func (g *gate) open(d time.Duration) bool {
	g.mu.Lock()
	shut, ch := g.shut, g.ch
	g.mu.Unlock()
	if !shut {
		return true
	}
	select {
	case <-ch:
	case <-time.After(d):
	}
	return false
}

// Half-close, so a client that has finished sending still gets its answer.
func closeWrite(c net.Conn) {
	if tc, ok := c.(*net.TCPConn); ok {
		tc.CloseWrite()
	}
}

func ipv4Addrs() ([]string, error) {
	ifaces, err := net.InterfaceAddrs()
	if err != nil {
		return nil, err
	}
	out := []string{"127.0.0.1"}
	for _, a := range ifaces {
		n, ok := a.(*net.IPNet)
		if !ok || n.IP.To4() == nil || n.IP.IsLoopback() || n.IP.IsLinkLocalUnicast() {
			continue
		}
		out = append(out, n.IP.String())
	}
	return out, nil
}
