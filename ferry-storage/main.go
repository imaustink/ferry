// ferry-storage gives a PersistentVolumeClaim somewhere to live.
//
// Without a provisioner a bare PVC sits Pending forever, and so does any chart
// with persistence in it -- which is most of the interesting ones. minikube
// ships storage-provisioner as a default addon and kind ships
// local-path-provisioner; ferry had neither.
//
// A volume here is a directory on the Mac. A claim that allows many writers is
// handed to the pod as a virtiofs share of it, which is how every other ferry
// mount already works; a single-writer claim also gets a disk image inside the
// directory, which ferry-cri attaches as a block device so the volume has real
// ownership (see singleWriter). Either way the volume is local to one machine,
// so the PersistentVolume carries node affinity and the StorageClass binds
// late: the scheduler picks a node for the pod first, and only then is a volume
// made on that node. A pod that comes back later is sent to the node holding
// its data.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/klog/v2"
)

const (
	provisionerName = "ferry.dev/local"
	// Set by the scheduler once it has chosen where a late-binding claim's pod
	// will run. It is the whole reason this works on more than one node.
	selectedNodeAnnotation = "volume.kubernetes.io/selected-node"
)

func main() {
	kubeconfig := flag.String("kubeconfig", "", "kubeconfig with access to claims and volumes")
	nodeName := flag.String("node-name", "", "this node; only claims assigned here are served")
	root := flag.String("root", "", "directory on this Mac to keep volumes in")
	className := flag.String("class", "ferry-local", "name of the StorageClass to offer")
	makeDefault := flag.Bool("default", true, "mark that class default, so a claim without one still binds")
	klog.InitFlags(nil)
	flag.Parse()

	if *kubeconfig == "" || *nodeName == "" || *root == "" {
		fmt.Fprintln(os.Stderr, "--kubeconfig, --node-name and --root are required")
		os.Exit(2)
	}
	if err := os.MkdirAll(*root, 0o755); err != nil {
		fmt.Fprintf(os.Stderr, "cannot use %s: %v\n", *root, err)
		os.Exit(1)
	}

	config, err := clientcmd.BuildConfigFromFlags("", *kubeconfig)
	if err != nil {
		klog.ErrorS(err, "Failed to read kubeconfig")
		os.Exit(1)
	}
	client, err := kubernetes.NewForConfig(config)
	if err != nil {
		klog.ErrorS(err, "Failed to build client")
		os.Exit(1)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	p := &provisioner{client: client, node: *nodeName, root: *root, class: *className}
	p.ensureClass(ctx, *makeDefault)

	factory := informers.NewSharedInformerFactory(client, 5*time.Minute)
	claims := factory.Core().V1().PersistentVolumeClaims()
	claims.Informer().AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc: func(obj any) { p.consider(ctx, obj) },
		UpdateFunc: func(_, obj any) { p.consider(ctx, obj) },
	})
	p.claims = claims.Lister()

	volumes := factory.Core().V1().PersistentVolumes()
	volumes.Informer().AddEventHandler(cache.ResourceEventHandlerFuncs{
		UpdateFunc: func(_, obj any) { p.reclaim(ctx, obj) },
		AddFunc:    func(obj any) { p.reclaim(ctx, obj) },
	})

	factory.Start(ctx.Done())
	factory.WaitForCacheSync(ctx.Done())
	fmt.Printf("==> ferry-storage\n    class     %s\n    volumes   %s\n    node      %s\n    serving\n",
		*className, *root, *nodeName)

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop
}
