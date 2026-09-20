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
// already runs its controllers natively. Out-of-cluster removes the bootstrap
// problem entirely: there is no chicken-and-egg where the thing that makes
// nodes needs a node to run on, and no Linux image to build and publish for it.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"

	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/utils/clock"
	controllerruntime "sigs.k8s.io/controller-runtime"

	"sigs.k8s.io/karpenter/pkg/controllers"
	"sigs.k8s.io/karpenter/pkg/controllers/nodeoverlay"
	"sigs.k8s.io/karpenter/pkg/controllers/state"
	"sigs.k8s.io/karpenter/pkg/events"
	"sigs.k8s.io/karpenter/pkg/operator"
)

// A FlagSet of its own rather than the global one.
//
// controller-runtime registers `-kubeconfig` on flag.CommandLine from an init
// function, so a package-level flag.String("kubeconfig", ...) here panics with
// "flag redefined" the moment anything imports it -- which `go test` finds
// before a human does. Importing a controller framework means importing its
// opinions about global state; keeping ferry's flags separate means they cannot
// collide with the next one it adds.
var flags = flag.NewFlagSet("ferry-karpenter", flag.ExitOnError)

var (
	kubeconfig = flags.String("kubeconfig", "", "kubeconfig for the cluster to provision for")
	image      = flags.String("image", "", "node disk image machines are cloned from; empty means ferry-machined's default")
	// Two different numbers that are easy to conflate: what one machine may be,
	// and what every machine together may be. Collapsing them means either a
	// single machine that can eat the whole budget, or a budget that silently
	// caps machine size.
	maxCPUs    = flags.Int64("limit-cpus", 8, "total cpus this Mac will commit to machines")
	maxMemory  = flags.Int64("limit-memory-gi", 16, "total memory in GiB this Mac will commit to machines")
	minCPUs    = flags.Int64("machine-min-cpus", 2, "smallest machine, in cpus")
	machMaxCPU = flags.Int64("machine-max-cpus", 8, "largest machine, in cpus")
	minMemory  = flags.Int64("machine-min-memory-gi", 2, "smallest machine, in GiB")
	maxMemoryM = flags.Int64("machine-max-memory-gi", 16, "largest machine, in GiB")
	maxPods    = flags.Int64("max-pods", 110, "pods a machine advertises")
)

func main() {
	if err := flags.Parse(os.Args[1:]); err != nil {
		log.Fatal(err)
	}
	log.SetFlags(log.Ltime)

	if *kubeconfig == "" {
		log.Fatal("--kubeconfig is required")
	}
	// Out-of-cluster, so the config comes from a file rather than a service
	// account. Everything else about the operator is unchanged.
	cfg, err := clientcmd.BuildConfigFromFlags("", *kubeconfig)
	if err != nil {
		log.Fatalf("kubeconfig: %v", err)
	}
	if err := useConfig(cfg); err != nil {
		log.Fatalf("config: %v", err)
	}

	dyn, err := dynamic.NewForConfig(cfg)
	if err != nil {
		log.Fatalf("dynamic client: %v", err)
	}

	// The NodeClass is built from flags rather than read from the cluster. It
	// describes the Mac -- what it will spend and what shapes it will boot --
	// and ferry already knows those from the process that started it. A cluster
	// object would be a second place for them to disagree.
	nodeClass := &FerryNodeClass{}
	nodeClass.Spec.Image = *image
	nodeClass.Spec.CPUs = Range{Min: *minCPUs, Max: *machMaxCPU}
	nodeClass.Spec.MemoryGi = Range{Min: *minMemory, Max: *maxMemoryM}
	nodeClass.Spec.Limits = Limits{CPUs: *maxCPUs, MemoryGi: *maxMemory}
	nodeClass.Spec.MaxPods = *maxPods

	provider := NewProvider(dyn, nodeClass)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	ctx, op := operator.NewOperator()
	mgr := op.Manager
	recorder := events.NewRecorder(mgr.GetEventRecorderFor("ferry-karpenter"))
	cluster := state.NewCluster(clock.RealClock{}, mgr.GetClient(), provider)
	store := nodeoverlay.NewInstanceTypeStore()

	log.Printf("==> ferry-karpenter")
	log.Printf("    limits   %d cpus, %d GiB in total", *maxCPUs, *maxMemory)
	log.Printf("    machines %d-%d cpus, %d-%d GiB", *minCPUs, *machMaxCPU, *minMemory, *maxMemoryM)
	shapes := nodeClass.bounds().shapes()
	log.Printf("    shapes   %d offered, %s to %s",
		len(shapes), shapes[0].name(), shapes[len(shapes)-1].name())

	op.WithControllers(ctx, controllers.NewControllers(
		ctx, mgr, clock.RealClock{}, mgr.GetClient(), recorder,
		provider, provider, cluster, store,
	)...).Start(ctx)
}

// useConfig points the operator's own client at the same cluster. Karpenter's
// operator reads its rest.Config from the ambient controller-runtime config,
// which out of cluster means KUBECONFIG rather than a service account.
func useConfig(cfg *rest.Config) error {
	if err := os.Setenv("KUBECONFIG", *kubeconfig); err != nil {
		return err
	}
	if _, err := controllerruntime.GetConfig(); err != nil {
		return fmt.Errorf("controller-runtime could not use %s: %w", *kubeconfig, err)
	}
	return nil
}
