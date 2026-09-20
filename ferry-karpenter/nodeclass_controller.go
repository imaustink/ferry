package main

// The controller that says a FerryNodeClass is usable.
//
// Karpenter will not provision from a NodePool whose NodeClass is not Ready --
// it logs "ignoring nodepool, not ready" and does nothing, forever, which looks
// exactly like a provisioner that is running and simply does not work. Nothing
// sets that condition by default: a provider is expected to have a controller
// that validates whatever its NodeClass refers to and reports the answer.
//
// For a cloud provider that means resolving AMIs, subnets and security groups.
// For ferry it means the far simpler question of whether this Mac can actually
// make the machines the class describes: a node image to clone, and a shape
// catalogue that is not empty. Both are cheap to check and both are worth
// checking, because the alternative is Ready meaning nothing.

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/awslabs/operatorpkg/status"
	"k8s.io/apimachinery/pkg/api/equality"
	controllerruntime "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/manager"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

type nodeClassController struct {
	kube client.Client
	// The bounds the provider provisions by, from ferry's environment -- not
	// the ones on the cluster object being reconciled. Those two are not the
	// same thing, and judging the wrong one makes Ready a claim about a spec
	// nothing reads. See the comment on usable.
	bounds bounds
	// The image every machine is cloned from, as ferry-machined was told it.
	// Empty means ferry-machined's own default, which this controller cannot
	// see and therefore does not claim to have checked.
	nodeDisk string
}

func (c *nodeClassController) Register(_ context.Context, m manager.Manager) error {
	return controllerruntime.NewControllerManagedBy(m).
		Named("ferrynodeclass.status").
		For(&FerryNodeClass{}).
		Complete(reconcile.AsReconciler(m.GetClient(), c))
}

func (c *nodeClassController) Reconcile(ctx context.Context, nc *FerryNodeClass) (reconcile.Result, error) {
	stored := nc.DeepCopy()

	if reason, ok := c.usable(nc); !ok {
		nc.StatusConditions().SetFalse(status.ConditionReady, "NotUsable", reason)
	} else {
		nc.StatusConditions().SetTrue(status.ConditionReady)
	}

	if !equality.Semantic.DeepEqual(stored, nc) {
		if err := c.kube.Status().Patch(ctx, nc, client.MergeFrom(stored)); err != nil {
			return reconcile.Result{}, fmt.Errorf("patching %s: %w", nc.Name, err)
		}
	}
	// Re-checked rather than latched. The node disk can be removed while the
	// cluster is up, and a NodeClass that stayed Ready would send Karpenter to
	// make machines from a file that is not there.
	return reconcile.Result{RequeueAfter: time.Minute}, nil
}

// Judged against ferry's own bounds rather than the reconciled object's spec.
//
// The provider provisions from the NodeClass main.go builds out of the
// environment, because those numbers describe the Mac and ferry already knows
// them. The cluster object exists so Karpenter has something to resolve a
// nodeClassRef against; its spec is not what anything provisions by. Reading
// the spec here would make Ready a statement about numbers with no effect --
// true while the Mac cannot fit a machine, or false while it can.
func (c *nodeClassController) usable(_ *FerryNodeClass) (string, bool) {
	b := c.bounds
	if len(b.shapes()) == 0 {
		return "the cpu and memory ranges admit no machine shape", false
	}
	// A budget smaller than the smallest machine provisions nothing, and says
	// so here rather than through pods that stay Pending with no explanation.
	smallest := b.shapes()[0]
	if !b.fits(shape{}, smallest) {
		return fmt.Sprintf("the budget of %d cpus and %d GiB cannot fit even %s",
			b.limitCPUs, b.limitMemoryGi, smallest.name()), false
	}
	if c.nodeDisk != "" {
		if _, err := os.Stat(c.nodeDisk); err != nil {
			return fmt.Sprintf("no node disk at %s", c.nodeDisk), false
		}
	}
	return "", true
}
