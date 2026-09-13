//go:build darwin

package nftables

// There is no kernel here to program, but kube-proxy's rule generation is
// exactly what ferry wants: reject rules for endpoint-less Services, hairpin
// masquerade, session affinity, endpoint selection. So on macOS the proxier
// runs against knftables' fake backend and the ruleset it would have applied is
// rendered instead. ferry pushes that into each pod, where a real kernel exists.

import (
	v1 "k8s.io/api/core/v1"
	"sigs.k8s.io/knftables"
)

// FerryRendered holds the ruleset of the most recently created proxier.
var FerryRendered *knftables.Fake

func ferryNFTablesInterface(ipFamily v1.IPFamily) (knftables.Interface, error) {
	family := knftables.IPv4Family
	if ipFamily != v1.IPv4Protocol {
		family = knftables.IPv6Family
	}
	FerryRendered = knftables.NewFake(family, kubeProxyTable)
	return FerryRendered, nil
}
