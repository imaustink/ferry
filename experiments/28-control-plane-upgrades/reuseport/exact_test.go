package main

// Whether a listener bound to one address beats wildcard listeners on the same
// port, whatever their age -- and so whether something bound to 127.0.0.1:P
// can stand in front of API servers bound to [::]:P while they change over.
//
//	go test -run Exact -v .
import (
	"context"
	"fmt"
	"net"
	"syscall"
	"testing"
)

func listenAt(addr string) (net.Listener, error) {
	lc := net.ListenConfig{Control: func(_, _ string, c syscall.RawConn) error {
		var serr error
		c.Control(func(fd uintptr) {
			serr = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_REUSEPORT, 1)
		})
		return serr
	}}
	return lc.Listen(context.Background(), "tcp", addr)
}

func TestExact(t *testing.T) {
	port := 23445
	wild, err := listenAt(fmt.Sprintf("0.0.0.0:%d", port))
	if err != nil {
		t.Fatal(err)
	}
	a := serve("wildcard-old", wild, 0)
	exact, err := listenAt(fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		t.Fatal("exact bind beside a wildcard:", err)
	}
	b := serve("exact", exact, 0)
	wild2, err := listenAt(fmt.Sprintf("0.0.0.0:%d", port))
	if err != nil {
		t.Fatal(err)
	}
	c := serve("wildcard-new", wild2, 0)
	for _, host := range []string{"127.0.0.1", "[::1]"} {
		fmt.Printf("wildcard, exact 127.0.0.1, wildcard; dialling %-9s -> %v\n", host,
			count(t, fmt.Sprintf("http://%s:%d/", host, port), 100))
	}
	a.ln.Close()
	fmt.Printf("oldest wildcard closed; dialling [::1]     -> %v\n", count(t, fmt.Sprintf("http://[::1]:%d/", port), 100))
	fmt.Printf("oldest wildcard closed; dialling 127.0.0.1 -> %v\n", count(t, fmt.Sprintf("http://127.0.0.1:%d/", port), 100))
	b.ln.Close()
	fmt.Printf("exact closed;           dialling 127.0.0.1 -> %v\n", count(t, fmt.Sprintf("http://127.0.0.1:%d/", port), 100))
	c.ln.Close()
}
