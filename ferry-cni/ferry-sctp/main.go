// ferry-sctp sends SCTP to the pod network over ferry's own switch.
//
// Every ferry pod has two ways to reach another pod. eth0 is vmnet, and carries
// the node's own slice -- the pods on this Mac -- on the hypervisor's datapath.
// eth1 is ferry's switch, and carries the rest of the cluster. The pod's routing
// table prefers the narrower of the two, so a conversation between two pods on
// one Mac never touches the switch. That is deliberate: it is the faster path.
//
// It is also a path that does not carry SCTP. vmnet forwards TCP, UDP and ICMP
// and drops the rest, which is invisible until something asks for a protocol
// outside that set:
//
//	same-node  SCTP -> timed out
//	cross-node SCTP -> ok
//
// The same association over eth1 works in both directions, so the switch is not
// the limitation and neither is the guest kernel, which has CONFIG_IP_SCTP. Only
// the vmnet hop is.
//
// So SCTP is given a routing table of its own: a rule matching the protocol,
// selecting a table whose route to the cluster leaves by eth1. Nothing else
// moves -- TCP and UDP keep the fast path, and cross-node SCTP was already going
// this way. A pod that never speaks SCTP is unaffected.
//
// This runs as a chained CNI plugin inside the pod, which is where routing
// decisions about a pod belong, and it is undone on DEL like any other.
package main

import (
	"encoding/json"
	"fmt"
	"net"

	"github.com/containernetworking/cni/pkg/skel"
	"github.com/containernetworking/cni/pkg/types"
	current "github.com/containernetworking/cni/pkg/types/100"
	"github.com/containernetworking/cni/pkg/version"
	"github.com/vishvananda/netlink"
	"golang.org/x/sys/unix"
)

// config is the plugin's stanza in the conflist, plus the chain's prevResult.
type config struct {
	types.NetConf

	// ClusterCIDR is an override, and is usually not what gets used.
	//
	// What this rule should redirect is "everything reachable over the switch",
	// and the switch interface already says what that is: it carries the pod
	// address with the cluster's prefix, so the network it is on is exactly the
	// set of addresses eth1 can reach. Reading it from the link rather than from
	// configuration means the plugin is right even when ferry did not get the
	// subnet it asked vmnet for and fell back to another one -- which happens,
	// and which left a configured CIDR pointing at a network no pod is on.
	ClusterCIDR string `json:"clusterCIDR"`
	// Device is the switch interface inside the pod.
	Device string `json:"device"`
	// Table and Priority are this plugin's own, kept out of the way of the
	// main table. 132 is SCTP's protocol number, used here as a memorable id
	// rather than for any meaning the kernel attaches to it.
	Table    int `json:"table"`
	Priority int `json:"priority"`
}

func parse(stdin []byte) (*config, error) {
	cfg := &config{Device: "eth1", Table: 132, Priority: 132}
	if err := json.Unmarshal(stdin, cfg); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}
	// Turns the raw prevResult JSON into the typed result this plugin passes on.
	if err := version.ParsePrevResult(&cfg.NetConf); err != nil {
		return nil, fmt.Errorf("parse prevResult: %w", err)
	}
	return cfg, nil
}

func add(args *skel.CmdArgs) error {
	cfg, err := parse(args.StdinData)
	if err != nil {
		return err
	}
	// A pod with no switch interface is a single-node cluster with nothing to
	// redirect to; leaving its routing alone is the correct outcome, not an
	// error that would fail the whole chain and with it the pod.
	link, err := netlink.LinkByName(cfg.Device)
	if err != nil {
		return passthrough(cfg)
	}
	// The route needs a source address or replies leave with the wrong one:
	// both interfaces hold the same address, and the kernel would otherwise
	// pick by the outgoing device.
	var src net.IP
	var dst *net.IPNet
	addrs, err := netlink.AddrList(link, netlink.FAMILY_V4)
	if err == nil && len(addrs) > 0 {
		src = addrs[0].IP
		dst = &net.IPNet{
			IP:   addrs[0].IP.Mask(addrs[0].Mask),
			Mask: addrs[0].Mask,
		}
	}
	if cfg.ClusterCIDR != "" {
		if _, override, err := net.ParseCIDR(cfg.ClusterCIDR); err == nil {
			dst = override
		}
	}
	if dst == nil {
		// No address on the switch and nothing configured: there is no network
		// to redirect to, which is not a failure worth failing the pod over.
		return passthrough(cfg)
	}

	route := &netlink.Route{
		LinkIndex: link.Attrs().Index,
		Dst:       dst,
		Src:       src,
		Table:     cfg.Table,
		Scope:     netlink.SCOPE_LINK,
	}
	if err := netlink.RouteReplace(route); err != nil {
		return fmt.Errorf("add route %s dev %s table %d: %w",
			cfg.ClusterCIDR, cfg.Device, cfg.Table, err)
	}

	// RuleAdd is not idempotent -- it will happily install the same rule twice --
	// so an existing one is removed first. CNI ADD can be retried.
	_ = netlink.RuleDel(ruleFor(cfg))
	if err := netlink.RuleAdd(ruleFor(cfg)); err != nil {
		return fmt.Errorf("add rule for sctp -> table %d: %w", cfg.Table, err)
	}
	return passthrough(cfg)
}

func del(args *skel.CmdArgs) error {
	cfg, err := parse(args.StdinData)
	if err != nil {
		return err
	}
	// Best effort throughout: DEL runs when the pod is going away, and a rule
	// that is already gone is the outcome this wanted.
	_ = netlink.RuleDel(ruleFor(cfg))
	if link, err := netlink.LinkByName(cfg.Device); err == nil {
		// Whatever is in this table belongs to this plugin, so the table is
		// emptied rather than matched against a CIDR that may have been
		// derived rather than configured.
		if routes, err := netlink.RouteListFiltered(netlink.FAMILY_V4,
			&netlink.Route{Table: cfg.Table, LinkIndex: link.Attrs().Index},
			netlink.RT_FILTER_TABLE|netlink.RT_FILTER_OIF); err == nil {
			for i := range routes {
				_ = netlink.RouteDel(&routes[i])
			}
		}
	}
	return nil
}

func check(args *skel.CmdArgs) error {
	cfg, err := parse(args.StdinData)
	if err != nil {
		return err
	}
	rules, err := netlink.RuleList(netlink.FAMILY_V4)
	if err != nil {
		return fmt.Errorf("list rules: %w", err)
	}
	for _, rule := range rules {
		if rule.IPProto == unix.IPPROTO_SCTP && rule.Table == cfg.Table {
			return nil
		}
	}
	return fmt.Errorf("no sctp rule selecting table %d", cfg.Table)
}

func ruleFor(cfg *config) *netlink.Rule {
	rule := netlink.NewRule()
	rule.IPProto = unix.IPPROTO_SCTP
	rule.Table = cfg.Table
	rule.Priority = cfg.Priority
	rule.Family = netlink.FAMILY_V4
	return rule
}

// passthrough hands the chain's result on unchanged. This plugin adds routing,
// not addresses, so it has nothing of its own to report.
func passthrough(cfg *config) error {
	result := cfg.PrevResult
	if result == nil {
		return types.PrintResult(&current.Result{CNIVersion: cfg.CNIVersion}, cfg.CNIVersion)
	}
	return types.PrintResult(result, cfg.CNIVersion)
}

func main() {
	skel.PluginMainFuncs(
		skel.CNIFuncs{Add: add, Del: del, Check: check},
		version.All, "ferry-sctp")
}
