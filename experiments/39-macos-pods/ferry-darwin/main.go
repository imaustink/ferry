// ferry-darwin: a CRI runtime for a macOS node, where pods share the node's
// XNU kernel.
//
// It is what `ferry-macos-shared` would name as its handler, served inside a
// macOS machine by ferry's darwin kubelet. Grown from experiment 01's fakecri,
// whose CRI surface the darwin kubelet already accepted; every call that was a
// record there does the work here. Must run as root on a node with SIP off --
// a chrooted process cannot map the shared cache otherwise.
//
//	ferry-darwin -endpoint SOCK -state DIR -mirror URL -shim podnet.dylib [-iface en0]
package main

import (
	"flag"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"google.golang.org/grpc"
	runtimeapi "k8s.io/cri-api/pkg/apis/runtime/v1"
)

func main() {
	endpoint := flag.String("endpoint", "/private/var/ferry/node/cri.sock", "unix socket to serve CRI on")
	state := flag.String("state", "/private/var/ferry/darwin", "runtime state: the OS base, images, pod roots")
	mirror := flag.String("mirror", "", "ferry-registry to pull through, e.g. http://192.168.1.29:45060")
	shim := flag.String("shim", "", "podnet.dylib, copied into every container root")
	iface := flag.String("iface", "en0", "interface pod addresses are aliased on")
	clusterCIDR := flag.String("cluster-cidr", "", "on ferry's pod network: the cluster CIDR; pods then take the node's pod CIDR on -iface")
	api := flag.String("api", "", "API server, for Services and EndpointSlices; empty leaves Services off")
	ca := flag.String("ca", "", "the cluster's CA certificate")
	clientCert := flag.String("client-cert", "/private/var/ferry/node/pki/kubelet-client-current.pem", "the kubelet's client certificate and key")
	clusterDNS := flag.String("cluster-dns", "", "the cluster DNS Service's ClusterIP, as the kubelet is told it")
	clusterDomain := flag.String("cluster-domain", "cluster.local", "the cluster's DNS domain")
	nodeName := flag.String("node-name", "", "this node's name, so the route agent skips it")
	streamAddr := flag.String("streaming", "127.0.0.1:10010", "address the exec and port-forward server listens on; the kubelet proxies to it")
	volumesRoot := flag.String("volumes-root", "", "the kubelet's pods directory, exported over NFS so volumes can be mounted into container roots; empty leaves volumes off")
	hostVolumes := flag.String("host-volumes", "", "the Mac's PersistentVolume directory, shared in at the same path; the runtime serves each volume under it over NFS itself")
	podVM := flag.Bool("pod-vm", false, "this machine is one pod's VM (ferry.dev/mode=macos-vm): its pod runs as root, because the boundary is the hypervisor, not a uid")
	prepare := flag.Bool("prepare", false, "copy the OS base into -state and exit (for baking a golden image)")
	flag.Parse()
	log.SetFlags(log.Lmicroseconds)
	if os.Geteuid() != 0 {
		log.Fatal("ferry-darwin must run as root: it chroots, changes uid, and owns pf")
	}

	start := time.Now()
	if *prepare {
		n := &node{state: *state, shim: *shim}
		if err := os.MkdirAll(filepath.Join(*state, "os"), 0o755); err != nil {
			log.Fatal(err)
		}
		if err := n.prepareOS(); err != nil {
			log.Fatal(err)
		}
		log.Printf("prepared %s in %s", *state, time.Since(start).Round(time.Millisecond))
		return
	}
	n, err := newNode(*state, *iface, *shim, *clusterCIDR)
	if err != nil {
		log.Fatalf("node: %v", err)
	}
	n.podVM = *podVM
	if n.clusterCIDR != nil {
		log.Printf("node: ready in %s; pods take this node's slice of %s on %s", time.Since(start).Round(time.Millisecond),
			n.clusterCIDR, *iface)
	} else {
		log.Printf("node: ready in %s; pods take %d.%d.%d.200 and up on %s", time.Since(start).Round(time.Millisecond),
			n.base[0], n.base[1], n.base[2], *iface)
	}

	images := &imageSvc{mirror: *mirror, dir: filepath.Join(*state, "images"), images: map[string]*image{}}
	rt := &runtimeSvc{node: n, images: images, sboxes: map[string]*sandbox{}, ctrs: map[string]*container{}}
	if *api != "" {
		rt.services = &serviceTable{api: *api, ca: *ca, cert: *clientCert, rt: rt,
			dnsIP: *clusterDNS, domain: *clusterDomain, reservedDNS: reservedDNSFor(n.clusterCIDR),
			nodeName: *nodeName, peerRoutes: map[string]string{}}
		go rt.services.run()
	}

	// nfsd takes ~10 s to export on a machine that has just booted, so it
	// comes up beside the runtime rather than before it: the node goes Ready
	// and pods without volumes start at once, and only a container with a
	// directory volume waits for it (see volumesUp).
	if *volumesRoot != "" {
		rt.volumesRoots = []string{filepath.Clean(*volumesRoot)}
		// Not an nfsd export: nfsd will not serve a virtiofs mount, and waited
		// 25 s for one before giving up. The runtime serves these itself.
		if *hostVolumes != "" {
			rt.hostVolumes = filepath.Clean(*hostVolumes)
		}
		rt.nfsReady = make(chan struct{})
		go func() {
			if exported, err := startNFS(rt.volumesRoots); err == nil {
				rt.volumesRoots = exported
			} else {
				log.Printf("volumes: %v; pods with volumes will not start", err)
				rt.nfsErr = err
			}
			close(rt.nfsReady)
		}()
	}
	if server, err := newStreamingServer(rt, *streamAddr); err != nil {
		log.Printf("streaming: %v; exec and port-forward are off", err)
	} else {
		rt.streaming = server
		go func() {
			if err := server.Start(true); err != nil {
				log.Printf("streaming: %v", err)
			}
		}()
	}

	_ = os.Remove(*endpoint)
	lis, err := net.Listen("unix", *endpoint)
	if err != nil {
		log.Fatalf("listen %s: %v", *endpoint, err)
	}
	srv := grpc.NewServer()
	runtimeapi.RegisterRuntimeServiceServer(srv, rt)
	runtimeapi.RegisterImageServiceServer(srv, images)

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-stop
		srv.Stop()
		_ = os.Remove(*endpoint)
		os.Exit(0)
	}()
	log.Printf("ferry-darwin serving CRI on unix://%s, handler %q, pulling through %s", *endpoint, handler, *mirror)
	if err := srv.Serve(lis); err != nil {
		log.Fatalf("serve: %v", err)
	}
}
