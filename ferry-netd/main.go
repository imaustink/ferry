// ferry-netd programs Service rules inside a pod's own kernel.
//
// It is a static Linux binary that ferry mounts into every pod and runs when
// the Service set changes. It reads a ruleset on stdin and replaces the pod's
// NAT table with it.
//
// The alternative was a kube-proxy in every pod: a process, an API watch and
// tens of megabytes each, in a design whose whole point is that pods are cheap.
// Here the rules are computed once on the host and applied; nothing is left
// running, and nothing watches the API from inside a pod.
//
// Running in the pod rather than on the host is what removes the two costs of
// proxying Services through the Mac -- needing root there, and sending every
// Service connection through it rather than pod to pod directly.
package main

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"net"
	"os"

	"github.com/google/nftables"
	"github.com/google/nftables/expr"
	"golang.org/x/sys/unix"
)

// Service is one ClusterIP:port and the endpoints behind it.
type Service struct {
	Name      string   `json:"name"`
	ClusterIP string   `json:"clusterIP"`
	Port      uint16   `json:"port"`
	Protocol  string   `json:"protocol"`
	Endpoints []string `json:"endpoints"` // "ip:port"
}

const tableName = "ferry"

func main() {
	var services []Service
	if err := json.NewDecoder(os.Stdin).Decode(&services); err != nil {
		fmt.Fprintf(os.Stderr, "read ruleset: %v\n", err)
		os.Exit(1)
	}

	conn, err := nftables.New()
	if err != nil {
		fmt.Fprintf(os.Stderr, "open netlink: %v\n", err)
		os.Exit(1)
	}

	// Replace wholesale rather than diffing. The ruleset is small, this runs
	// only when it changes, and a full replace cannot drift from the host's
	// view of the world.
	conn.DelTable(&nftables.Table{Family: nftables.TableFamilyIPv4, Name: tableName})
	_ = conn.Flush() // a missing table is not an error worth reporting

	table := conn.AddTable(&nftables.Table{Family: nftables.TableFamilyIPv4, Name: tableName})

	// Output covers traffic the pod itself originates, which is every Service
	// connection a container makes. Prerouting is not needed: nothing routes
	// through a pod.
	output := conn.AddChain(&nftables.Chain{
		Name: "services", Table: table,
		Type: nftables.ChainTypeNAT, Hooknum: nftables.ChainHookOutput,
		Priority: nftables.ChainPriorityNATDest,
	})

	applied := 0
	for _, service := range services {
		if len(service.Endpoints) == 0 || service.ClusterIP == "" {
			continue
		}
		if service.Protocol != "" && service.Protocol != "TCP" {
			continue // UDP and SCTP are not handled yet
		}
		clusterIP := net.ParseIP(service.ClusterIP).To4()
		if clusterIP == nil {
			continue
		}
		for index, endpoint := range service.Endpoints {
			host, port, err := splitEndpoint(endpoint)
			if err != nil {
				continue
			}
			rule := matchService(table, output, clusterIP, service.Port)
			// Spread connections across endpoints the way kube-proxy does:
			// each rule takes a 1-in-N slice of a random draw.
			if len(service.Endpoints) > 1 {
				rule.Exprs = append(rule.Exprs,
					&expr.Numgen{Register: 3, Modulus: uint32(len(service.Endpoints)), Type: unix.NFT_NG_RANDOM},
					&expr.Cmp{Op: expr.CmpOpEq, Register: 3, Data: binaryLE32(uint32(index))},
				)
			}
			rule.Exprs = append(rule.Exprs,
				&expr.Immediate{Register: 1, Data: host},
				&expr.Immediate{Register: 2, Data: bigEndian16(port)},
				&expr.NAT{
					Type: expr.NATTypeDestNAT, Family: uint32(nftables.TableFamilyIPv4),
					RegAddrMin: 1, RegProtoMin: 2,
				},
			)
			conn.AddRule(rule)
			applied++
		}
	}

	if err := conn.Flush(); err != nil {
		fmt.Fprintf(os.Stderr, "apply ruleset: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("ferry-netd: %d services, %d rules\n", len(services), applied)
}

// matchService builds the part of a rule that selects one ClusterIP and port.
func matchService(table *nftables.Table, chain *nftables.Chain, clusterIP net.IP, port uint16) *nftables.Rule {
	return &nftables.Rule{
		Table: table, Chain: chain,
		Exprs: []expr.Any{
			&expr.Meta{Key: expr.MetaKeyL4PROTO, Register: 1},
			&expr.Cmp{Op: expr.CmpOpEq, Register: 1, Data: []byte{6}}, // tcp
			&expr.Payload{DestRegister: 1, Base: expr.PayloadBaseNetworkHeader, Offset: 16, Len: 4},
			&expr.Cmp{Op: expr.CmpOpEq, Register: 1, Data: clusterIP},
			&expr.Payload{DestRegister: 1, Base: expr.PayloadBaseTransportHeader, Offset: 2, Len: 2},
			&expr.Cmp{Op: expr.CmpOpEq, Register: 1, Data: bigEndian16(port)},
		},
	}
}

func splitEndpoint(endpoint string) (net.IP, uint16, error) {
	host, port, err := net.SplitHostPort(endpoint)
	if err != nil {
		return nil, 0, err
	}
	ip := net.ParseIP(host).To4()
	if ip == nil {
		return nil, 0, fmt.Errorf("not an IPv4 address: %s", host)
	}
	var value uint16
	if _, err := fmt.Sscanf(port, "%d", &value); err != nil {
		return nil, 0, err
	}
	return ip, value, nil
}

// Ports travel in network byte order; numgen comparisons are host order.
func bigEndian16(v uint16) []byte {
	out := make([]byte, 2)
	binary.BigEndian.PutUint16(out, v)
	return out
}

func binaryLE32(v uint32) []byte {
	out := make([]byte, 4)
	binary.LittleEndian.PutUint32(out, v)
	return out
}
