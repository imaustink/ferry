// How macOS hands out connections between two SO_REUSEPORT listeners, and
// what a client sees when one of them goes away.
//
// kube-apiserver's --permit-port-sharing sets SO_REUSEPORT on its listener.
// Whether that makes a handover possible -- a new API server binding the port
// an old one still holds, then the old one leaving -- depends on the kernel's
// answer to three questions, which this asks directly:
//
//  1. can a second listener bind at all, and does it need the first to have
//     set the option too;
//  2. once both are bound, which one gets a new connection;
//  3. when one closes, do connections already queued to it survive, and do
//     new ones go to the other.
//
//	go run . [-port 23443] [-clients 8] [-phase 1s]
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

func listen(port int, reuse bool) (net.Listener, error) {
	lc := net.ListenConfig{Control: func(_, _ string, c syscall.RawConn) error {
		if !reuse {
			return nil
		}
		var serr error
		if err := c.Control(func(fd uintptr) {
			serr = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_REUSEPORT, 1)
		}); err != nil {
			return err
		}
		return serr
	}}
	return lc.Listen(context.Background(), "tcp", fmt.Sprintf("0.0.0.0:%d", port))
}

type server struct {
	srv *http.Server
	ln  net.Listener
}

func serve(id string, ln net.Listener, work time.Duration) *server {
	s := &server{ln: ln}
	s.srv = &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		time.Sleep(work) // something in flight at any moment
		io.WriteString(w, id)
	})}
	go s.srv.Serve(ln)
	return s
}

type tally struct {
	mu    sync.Mutex
	byID  map[string]int
	errs  map[string]int
	total int
}

func newTally() *tally { return &tally{byID: map[string]int{}, errs: map[string]int{}} }

func (t *tally) add(id string, err error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.total++
	if err != nil {
		msg := err.Error()
		var op *net.OpError
		if errors.As(err, &op) && op.Err != nil {
			msg = op.Op + ": " + op.Err.Error()
		}
		t.errs[msg]++
		return
	}
	t.byID[id]++
}

func (t *tally) String() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	nerr := 0
	for _, n := range t.errs {
		nerr += n
	}
	return fmt.Sprintf("%5d requests  answered by %v  failed %d %v", t.total, t.byID, nerr, t.errs)
}

// Clients hammer the port until stop is closed, each request on a connection
// of its own (keepAlive false) or on a pooled one (true), counting into
// whatever tally cur points at when the request finishes.
func hammer(port, n int, keepAlive bool, cur *atomic.Pointer[tally], stop chan struct{}, wg *sync.WaitGroup) {
	tr := &http.Transport{DisableKeepAlives: !keepAlive, MaxIdleConnsPerHost: n}
	c := &http.Client{Transport: tr, Timeout: 5 * time.Second}
	url := fmt.Sprintf("http://127.0.0.1:%d/", port)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
				}
				resp, err := c.Get(url)
				id := ""
				if err == nil {
					b, _ := io.ReadAll(resp.Body)
					resp.Body.Close()
					id = string(b)
				}
				cur.Load().add(id, err)
				time.Sleep(2 * time.Millisecond)
			}
		}()
	}
}

func must(l net.Listener, err error) net.Listener {
	if err != nil {
		fmt.Println("listen:", err)
		os.Exit(1)
	}
	return l
}

func main() {
	port := flag.Int("port", 23443, "port to share")
	clients := flag.Int("clients", 8, "concurrent clients")
	phase := flag.Duration("phase", time.Second, "length of each phase")
	work := flag.Duration("work", 5*time.Millisecond, "time each request takes to answer")
	flag.Parse()

	fmt.Println("== can a second listener bind?")
	plain := must(listen(*port, false))
	_, err := listen(*port, true)
	fmt.Printf("  first without SO_REUSEPORT, second with it: %v\n", errOr(err, "bound"))
	plain.Close()
	first := must(listen(*port, true))
	_, err = listen(*port, false)
	fmt.Printf("  first with SO_REUSEPORT, second without it: %v\n", errOr(err, "bound"))
	first.Close()

	for _, keepAlive := range []bool{false, true} {
		mode := "a new connection per request"
		if keepAlive {
			mode = "pooled keep-alive connections"
		}
		fmt.Printf("\n== %d clients, %s\n", *clients, mode)
		old := serve("old", must(listen(*port, true)), *work)
		var cur atomic.Pointer[tally]
		stop := make(chan struct{})
		var wg sync.WaitGroup
		t := newTally()
		cur.Store(t)
		hammer(*port, *clients, keepAlive, &cur, stop, &wg)

		time.Sleep(*phase)
		fmt.Println("  old alone:           ", t)

		nw := serve("new", must(listen(*port, true)), *work)
		t = newTally()
		cur.Store(t)
		time.Sleep(*phase)
		fmt.Println("  both bound:          ", t)

		// The handover: what an API server does on SIGTERM once its shutdown
		// delay is up -- close the listener, finish what is in flight.
		t = newTally()
		cur.Store(t)
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		old.srv.Shutdown(ctx)
		cancel()
		time.Sleep(*phase)
		fmt.Println("  old shut down:       ", t)

		// The rude version: the listener closed with no drain at all, as a
		// SIGKILL would. A third listener first, so there is somewhere to go.
		n2 := serve("new2", must(listen(*port, true)), *work)
		time.Sleep(*phase / 4)
		t = newTally()
		cur.Store(t)
		nw.ln.Close()
		nw.srv.Close()
		time.Sleep(*phase)
		fmt.Println("  new killed, new2 up: ", t)

		close(stop)
		wg.Wait()
		n2.srv.Close()
	}
}

func errOr(err error, ok string) string {
	if err != nil {
		return err.Error()
	}
	return ok
}
