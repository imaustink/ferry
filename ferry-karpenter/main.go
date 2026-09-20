// ferry-karpenter provisions machines for pods that have nowhere to run, and
// takes them away again when they are empty.
//
// It is Karpenter, used as a library, with ferry as its cloud provider. What it
// adds to mode 2 is the thing that makes mode 2 usable as a default: nobody
// declares a Machine or chooses its size. A pod that does not fit causes a node
// shaped to fit it, and an idle node gives its memory back to the Mac.
//
// It runs as a native macOS process beside ferry-machined and the control
// plane, not as a pod in the cluster it provisions for. docs/MACHINES.md
// expected the opposite and listed "Karpenter runs as a pod" as an argument
// against using it -- but Karpenter v1 is a library with no webhooks, and ferry
// already runs its controllers natively. Out of cluster removes the bootstrap
// problem entirely: there is no chicken and egg where the thing that makes
// nodes needs a node to run on, and no Linux image to build and publish for it.
//
// The command line belongs to Karpenter. Its operator parses os.Args with its
// own flag set and refuses to start on an argument it does not recognise, so
// ferry's settings arrive through the environment -- see config.go -- and
// anything passed here is Karpenter's own.
package main

import (
	"log"
	"os"

	"k8s.io/utils/clock"

	"sigs.k8s.io/karpenter/pkg/controllers"
	"sigs.k8s.io/karpenter/pkg/controllers/nodeoverlay"
	"sigs.k8s.io/karpenter/pkg/controllers/state"
	"sigs.k8s.io/karpenter/pkg/events"
	"sigs.k8s.io/karpenter/pkg/operator"

	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/tools/clientcmd"
)

func main() {
	log.SetFlags(log.Ltime)

	kubeconfig := os.Getenv("KUBECONFIG")
	if kubeconfig == "" {
		log.Fatal("KUBECONFIG must point at the cluster to provision for")
	}
	cfg, err := clientcmd.BuildConfigFromFlags("", kubeconfig)
	if err != nil {
		log.Fatalf("kubeconfig: %v", err)
	}
	dyn, err := dynamic.NewForConfig(cfg)
	if err != nil {
		log.Fatalf("dynamic client: %v", err)
	}

	// Built here rather than read from the cluster. It describes the Mac --
	// what it will spend, and what shapes it will boot -- and ferry already
	// knows those from the process that started this. A cluster object would be
	// a second place for them to disagree.
	conf := configFromEnv()
	nodeClass := conf.nodeClass()
	provider := NewProvider(dyn, nodeClass)

	shapes := nodeClass.bounds().shapes()
	log.Printf("==> ferry-karpenter")
	log.Printf("    budget   %d cpus and %d GiB across all machines",
		conf.bounds.limitCPUs, conf.bounds.limitMemoryGi)
	log.Printf("    machines %d-%d cpus, %d-%d GiB",
		conf.bounds.minCPUs, conf.bounds.maxCPUs, conf.bounds.minMemoryGi, conf.bounds.maxMemoryGi)
	log.Printf("    shapes   %d offered, %s to %s",
		len(shapes), shapes[0].name(), shapes[len(shapes)-1].name())

	// NewOperator reads the cluster from controller-runtime's ambient config,
	// which out of cluster is KUBECONFIG -- already set, since it is how this
	// process was told where to connect.
	ctx, op := operator.NewOperator()
	mgr := op.Manager
	recorder := events.NewRecorder(mgr.GetEventRecorderFor("ferry-karpenter"))
	cluster := state.NewCluster(clock.RealClock{}, mgr.GetClient(), provider)
	store := nodeoverlay.NewInstanceTypeStore()

	// Karpenter's own controllers, plus the one that says whether this Mac can
	// make the machines the NodeClass describes. Without that last one the
	// NodePool never becomes ready and the provisioner runs happily, forever,
	// provisioning nothing.
	all := controllers.NewControllers(
		ctx, mgr, clock.RealClock{}, mgr.GetClient(), recorder,
		provider, provider, cluster, store,
	)
	all = append(all, &nodeClassController{
		kube:     mgr.GetClient(),
		bounds:   conf.bounds,
		nodeDisk: os.Getenv("FERRY_NODE_DISK"),
	})

	op.WithControllers(ctx, all...).Start(ctx)
}
