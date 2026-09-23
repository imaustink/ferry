// ferry-registry hands a mode 2 machine the images this Mac already has.
//
// `ferry image load` and `ferry image build` put an image into ferry-cri's
// store, which only mode 1 reads. A machine is a node of its own with its own
// containerd, so a pod scheduled onto one looked for a locally built image in a
// registry that had never heard of it and failed with ErrImageNeverPull, or
// ErrImagePull if it was allowed to try.
//
// So the same images are also kept here, as one OCI layout, and served over the
// read half of the registry API to the machine network, which reaches it at the
// gateway -- the Mac, as every machine sees it. A machine's containerd is told
// to try this first for every registry and to fall through to the real one
// when it answers 404, so a pod's image reference means the same thing on a
// machine as it does on the Mac, and nothing in a manifest has to change.
//
// Read-only on purpose. Pushing is `ferry-registry add`, run by ferry on the
// Mac: a registry that accepts pushes from the network is a second way in to
// every node, and nothing needs one.
//
// It listens on every interface and answers only the machine subnet and
// loopback, rather than binding the gateway address. vmnet creates the Mac's
// side of the network -- the bridge that holds the gateway -- only while a
// machine is attached, and removes it when the last one goes, which the
// provisioner does to every empty machine. Bound to the gateway, this could
// not start before the first machine and would lose its address with the last.
//
//	ferry-registry serve --store DIR --listen ADDR --allow CIDR[,CIDR]
//	ferry-registry add   --store DIR LAYOUT
//	ferry-registry list  --store DIR
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	flags := flag.NewFlagSet(os.Args[1], flag.ExitOnError)
	store := flags.String("store", "", "the OCI layout images are kept in")
	listen := flags.String("listen", "", "address to serve on (serve)")
	allow := flags.String("allow", "", "comma-separated CIDRs answered besides loopback (serve)")
	flags.Parse(os.Args[2:])
	if *store == "" {
		usage()
	}

	switch os.Args[1] {
	case "serve":
		if *listen == "" {
			usage()
		}
		var nets []*net.IPNet
		for _, cidr := range strings.Split(*allow, ",") {
			if cidr = strings.TrimSpace(cidr); cidr == "" {
				continue
			}
			_, n, err := net.ParseCIDR(cidr)
			if err != nil {
				log.Fatalf("--allow %s: %v", cidr, err)
			}
			nets = append(nets, n)
		}
		serve(*store, *listen, nets)
	case "add":
		if flags.NArg() != 1 {
			usage()
		}
		added, err := add(*store, flags.Arg(0))
		for _, name := range added {
			fmt.Println(name)
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, "ferry-registry:", err)
			os.Exit(1)
		}
	case "list":
		list, err := names(*store)
		if err != nil {
			fmt.Fprintln(os.Stderr, "ferry-registry:", err)
			os.Exit(1)
		}
		for _, name := range list {
			fmt.Println(name)
		}
	default:
		usage()
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: ferry-registry serve --store DIR --listen ADDR [--allow CIDR,...]")
	fmt.Fprintln(os.Stderr, "       ferry-registry add   --store DIR LAYOUT")
	fmt.Fprintln(os.Stderr, "       ferry-registry list  --store DIR")
	os.Exit(2)
}

func serve(store, listen string, allow []*net.IPNet) {
	if err := os.MkdirAll(store, 0o755); err != nil {
		log.Fatal(err)
	}
	server := &http.Server{
		Addr:              listen,
		Handler:           logged(only(allow, &registry{store: store})),
		ReadHeaderTimeout: 10 * time.Second,
	}
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-stop
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		server.Shutdown(ctx)
	}()
	log.Printf("serving %s on %s to %v and loopback", store, listen, allow)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

// logged writes a line per request. A machine that pulls from upstream when it
// was meant to pull from here looks exactly like one that works, and this log
// is where the difference shows: a 404 for a name that should be stored is the
// name not matching, and no line at all is the mirror not being used.
func logged(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec := &status{ResponseWriter: w, code: http.StatusOK}
		next.ServeHTTP(rec, r)
		log.Printf("%s %s %s %d", r.RemoteAddr, r.Method, r.URL.RequestURI(), rec.code)
	})
}

// only refuses anyone outside the given networks and loopback.
func only(allow []*net.IPNet, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		ip := net.ParseIP(host)
		if err != nil || ip == nil {
			fail(w, http.StatusForbidden, "DENIED", "unknown client")
			return
		}
		if ip.IsLoopback() {
			next.ServeHTTP(w, r)
			return
		}
		for _, n := range allow {
			if n.Contains(ip) {
				next.ServeHTTP(w, r)
				return
			}
		}
		fail(w, http.StatusForbidden, "DENIED", "this registry serves this Mac's machines only")
	})
}

type status struct {
	http.ResponseWriter
	code int
}

func (s *status) WriteHeader(code int) {
	s.code = code
	s.ResponseWriter.WriteHeader(code)
}
