package main

// Which bind combinations macOS accepts on one port. The handover needs two:
// an exact-address listener beside a wildcard one that may not have set
// anything (an API server started before ferry passed --permit-port-sharing),
// and a wildcard beside exact listeners.
//
//	go test -run Combos -v .
import (
	"context"
	"fmt"
	"net"
	"syscall"
	"testing"
)

func listenOpts(addr string, reuseAddr, reusePort bool) (net.Listener, error) {
	lc := net.ListenConfig{Control: func(_, _ string, c syscall.RawConn) error {
		var serr error
		c.Control(func(fd uintptr) {
			if reuseAddr {
				serr = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_REUSEADDR, 1)
			}
			if serr == nil && reusePort {
				serr = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_REUSEPORT, 1)
			}
		})
		return serr
	}}
	return lc.Listen(context.Background(), "tcp", addr)
}

func TestCombos(t *testing.T) {
	port := 23446
	type opt struct{ addr, port bool }
	name := func(o opt) string {
		switch {
		case o.addr && o.port:
			return "REUSEADDR+REUSEPORT"
		case o.addr:
			return "REUSEADDR"
		case o.port:
			return "REUSEPORT"
		}
		return "nothing"
	}
	opts := []opt{{false, false}, {true, false}, {false, true}, {true, true}}
	for _, first := range []string{"0.0.0.0", "127.0.0.1"} {
		second := "127.0.0.1"
		if first == "127.0.0.1" {
			second = "0.0.0.0"
		}
		for _, a := range opts {
			for _, b := range opts {
				l1, err := listenOpts(fmt.Sprintf("%s:%d", first, port), a.addr, a.port)
				if err != nil {
					t.Fatal(err)
				}
				l2, err := listenOpts(fmt.Sprintf("%s:%d", second, port), b.addr, b.port)
				res := "ok"
				if err != nil {
					res = "EADDRINUSE"
				} else {
					l2.Close()
				}
				fmt.Printf("%-9s with %-19s then %-9s with %-19s: %s\n", first, name(a), second, name(b), res)
				l1.Close()
			}
		}
	}
}
