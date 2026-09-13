//go:build darwin

package conntrack

// Conntrack on macOS, where there is none.
//
// ferry runs kube-proxy's rule generation on the host to render a ruleset, then
// applies it inside each pod. Reconciling conntrack is the one part that cannot
// be rendered: it acts on a live kernel's connection table, and the host has no
// such table. The entries that matter live in each pod's own kernel.
//
// The proxier only holds this interface and hands it back, so a stub is enough
// for the rule generation to run.

import (
	v1 "k8s.io/api/core/v1"
	"k8s.io/kubernetes/pkg/proxy"
)

// Interface is the subset the proxier refers to. It has no methods here because
// the proxier never calls any -- it passes the value to CleanStaleEntries.
type Interface interface{}

func New() Interface { return nil }

// CleanStaleEntries does nothing on macOS. Stale entries in a pod's kernel are
// a real concern and are noted in docs/SERVICES.md as unhandled.
func CleanStaleEntries(ct Interface, ipFamily v1.IPFamily,
	svcPortMap proxy.ServicePortMap, endpointsMap proxy.EndpointsMap) {
}
