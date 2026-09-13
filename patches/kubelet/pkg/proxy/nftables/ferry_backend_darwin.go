//go:build darwin

package nftables

// There is no kernel here to program, but kube-proxy's rule generation is
// exactly what ferry wants: reject rules for endpoint-less Services, hairpin
// masquerade, session affinity, endpoint selection. So on macOS the proxier
// runs against knftables' fake backend and the ruleset it would have applied is
// rendered instead. ferry pushes that into each pod, where a real kernel exists.

import (
	"context"

	v1 "k8s.io/api/core/v1"
	"sigs.k8s.io/knftables"
)

// FerryRendered holds the ruleset of the most recently created proxier.
var FerryRendered *knftables.Fake

// FerryApplied receives a value each time the proxier finishes a transaction,
// which is the moment FerryRendered's contents change. Without it the only way
// to notice a new ruleset is to poll Dump() and compare, which costs a full
// render per tick and delays every change by up to one tick. Buffered by one
// and sent to without blocking: a pending signal already says what a second one
// would.
var FerryApplied = make(chan struct{}, 1)

// ferryFake is knftables' fake backend that says when it has been written to.
type ferryFake struct {
	*knftables.Fake
}

func (f ferryFake) Run(ctx context.Context, tx *knftables.Transaction) error {
	if err := f.Fake.Run(ctx, tx); err != nil {
		return err
	}
	select {
	case FerryApplied <- struct{}{}:
	default:
	}
	return nil
}

func ferryNFTablesInterface(ipFamily v1.IPFamily) (knftables.Interface, error) {
	family := knftables.IPv4Family
	if ipFamily != v1.IPv4Protocol {
		family = knftables.IPv6Family
	}
	FerryRendered = knftables.NewFake(family, kubeProxyTable)
	return ferryFake{FerryRendered}, nil
}
