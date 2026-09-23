// ferry-machined turns Machine resources into virtual machines that are nodes.
//
// The split is the one ferry already uses: the Go half talks to the API server,
// and the Swift half talks to Virtualization.framework. ferry-machined watches
// Machines and calls ferry-node to build a disk and boot a machine, the same
// way ferry-streamer watches pods and ferry-cri makes them.
//
// What a machine needs before it can join is a certificate authority to trust,
// an address to answer on, and a token to authenticate its first request. The
// first two are the VM's business and ferry-node handles them; the token is a
// cluster object, so it is made here, one per machine, and removed with it.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/tools/clientcmd"
)

var (
	kubeconfig = flag.String("kubeconfig", "", "kubeconfig for the cluster to serve")
	kernel     = flag.String("kernel", "", "guest kernel every machine boots")
	baseImage  = flag.String("image", "", "node disk image machines are cloned from")
	stateDir   = flag.String("state", "/tmp/ferry-machined", "where per-machine disks and logs live")
	apiServer  = flag.String("api-server", "", "https://host:port machines join, reachable from a VM")
	caFile     = flag.String("ca", "", "cluster CA the machines must trust")
	// No --cluster-dns here. It was declared and never read, which made it look
	// like the place cluster DNS is configured while the value went nowhere: a
	// machine's kubelet takes its clusterDNS from the boot arguments
	// `ferry-node serve` writes, so --cluster-dns belongs to that process.
	interval    = flag.Duration("interval", 2*time.Second, "how often to reconcile")
	machinesDir = flag.String("machines", "", "directory ferry-node serve watches; defaults to <state>/machines")
	// The Mac's own node. Every machine is labelled ferry.dev/host with it, so
	// ferry-storage can pin a volume to "anywhere on this Mac" -- the Mac and
	// its machines share one volumes directory -- rather than to one node.
	hostNode = flag.String("host-node", "", "the Mac's own node name, labelled on each machine as ferry.dev/host")
)

func main() {
	flag.Parse()
	// Unbuffered, like ferry-cri: this process is watched through a log file and
	// a block buffer makes a working controller look like a stuck one.
	log.SetFlags(log.Ltime)

	for name, value := range map[string]*string{
		"--kubeconfig": kubeconfig, "--image": baseImage,
	} {
		if *value == "" {
			log.Fatalf("%s is required", name)
		}
	}
	if err := os.MkdirAll(*stateDir, 0o755); err != nil {
		log.Fatalf("state directory: %v", err)
	}
	if *machinesDir == "" {
		*machinesDir = filepath.Join(*stateDir, "machines")
	}
	if err := os.MkdirAll(*machinesDir, 0o755); err != nil {
		log.Fatalf("machines directory: %v", err)
	}

	config, err := clientcmd.BuildConfigFromFlags("", *kubeconfig)
	if err != nil {
		log.Fatalf("kubeconfig: %v", err)
	}
	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		log.Fatalf("client: %v", err)
	}
	dynamicClient, err := dynamic.NewForConfig(config)
	if err != nil {
		log.Fatalf("dynamic client: %v", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	controller := &controller{
		kube:     clientset,
		dynamic:  dynamicClient,
		machines: map[string]*machine{},
	}

	if err := controller.ensureBootstrapRBAC(ctx); err != nil {
		log.Fatalf("bootstrap RBAC: %v", err)
	}

	// Machines asked for by an earlier controller are still running.
	if err := controller.adopt(); err != nil {
		log.Printf("adopting existing machines: %v", err)
	}

	log.Printf("==> ferry-machined")
	log.Printf("    image   %s", *baseImage)
	log.Printf("    kernel  %s", *kernel)
	log.Printf("    join    %s", *apiServer)
	log.Printf("    state   %s", *stateDir)
	log.Printf("    machines %s", *machinesDir)

	// Pods, claims and volumes from a cache rather than listed every tick:
	// deciding which machine holds which disk reads all three, twice a second
	// would be a list of every pod in the cluster.
	factory := informers.NewSharedInformerFactory(clientset, 10*time.Minute)
	disks := &attacher{
		pods:    factory.Core().V1().Pods().Lister(),
		claims:  factory.Core().V1().PersistentVolumeClaims().Lister(),
		volumes: factory.Core().V1().PersistentVolumes().Lister(),
	}
	// A pod scheduled onto a machine is waiting on its disk from that moment,
	// so a pod or claim change reconciles the disks at once rather than at the
	// next tick: the tick alone was a second on average added to every pod
	// start with a block claim.
	kick := make(chan struct{}, 1)
	poke := func() {
		select {
		case kick <- struct{}{}:
		default:
		}
	}
	handler := cache.ResourceEventHandlerFuncs{
		AddFunc:    func(any) { poke() },
		UpdateFunc: func(_, _ any) { poke() },
		DeleteFunc: func(any) { poke() },
	}
	factory.Core().V1().Pods().Informer().AddEventHandler(handler)
	factory.Core().V1().PersistentVolumeClaims().Informer().AddEventHandler(handler)
	factory.Start(ctx.Done())
	factory.WaitForCacheSync(ctx.Done())

	ticker := time.NewTicker(*interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			// The machines keep running. A controller is not something a node's
			// life should depend on, and the next one adopts them.
			log.Printf("exiting; %d machine(s) keep running", len(controller.machines))
			return
		case <-kick:
			names := map[string]bool{}
			for name := range controller.machines {
				names[name] = true
			}
			disks.reconcile(names)
		case <-ticker.C:
			if err := controller.reconcileAll(ctx); err != nil {
				log.Printf("reconcile: %v", err)
			}
			names := map[string]bool{}
			for name := range controller.machines {
				names[name] = true
			}
			disks.reconcile(names)
		}
	}
}

// diskPath is where a machine's root filesystem lives. One per machine: a node
// writes to its own disk, and machines are replaced rather than reset.
func diskPath(name string) string {
	return filepath.Join(*stateDir, fmt.Sprintf("%s.ext4", name))
}

// The machines directory is the control channel to ferry-node serve: a spec
// file asks for a machine, and removing it stops one. Shared with the server
// rather than private to either.
func specFile(name string) string {
	return filepath.Join(*machinesDir, fmt.Sprintf("%s.json", name))
}

func statusFile(name string) string {
	return filepath.Join(*machinesDir, fmt.Sprintf("%s.status.json", name))
}
