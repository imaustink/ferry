//go:build linux

package nftables

import (
	v1 "k8s.io/api/core/v1"
	"sigs.k8s.io/knftables"
)

// On Linux the proxier programs the kernel directly, as upstream intends.
func ferryNFTablesInterface(ipFamily v1.IPFamily) (knftables.Interface, error) {
	return getNFTablesInterface(ipFamily)
}
