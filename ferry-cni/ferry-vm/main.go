// ferry-vm is ferry's CNI main plugin, and it is deliberately almost empty.
//
// A main plugin's entire job is to create a network namespace and put an
// addressed interface in it. On this system the hypervisor does that: a pod is
// a virtual machine, so the netns is a kernel and the interface is a virtio
// NIC the framework configures from a value type. There is nothing for a plugin
// to do with netlink because there is no netlink to do it with.
//
// So what remains is the part that is genuinely CNI's: choose the address, and
// describe the interface that will carry it. This plugin delegates the first to
// an ordinary upstream IPAM plugin -- host-local builds native Mach-O and needs
// no Linux at all -- and reports the second, which ferry-cri then builds.
//
// It runs before the VM exists. That is not a compromise: Virtualization.framework
// cannot hotplug a device, so the address has to be known before boot anyway.
// The no-hotplug limitation is what makes the IPAM/main split forced rather
// than chosen.
package main

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/containernetworking/cni/pkg/invoke"
	"github.com/containernetworking/cni/pkg/skel"
	"github.com/containernetworking/cni/pkg/types"
	current "github.com/containernetworking/cni/pkg/types/100"
	"github.com/containernetworking/cni/pkg/version"
)

// buildVersion is stamped by build.sh so `ferry-vm` reports something useful
// in a chain that fails.
var buildVersion = "dev"

type netConf struct {
	types.NetConf
}

func parse(stdin []byte) (*netConf, error) {
	conf := &netConf{}
	if err := json.Unmarshal(stdin, conf); err != nil {
		return nil, fmt.Errorf("parse the network configuration: %w", err)
	}
	return conf, nil
}

func cmdAdd(args *skel.CmdArgs) error {
	conf, err := parse(args.StdinData)
	if err != nil {
		return err
	}
	if conf.IPAM.Type == "" {
		return fmt.Errorf("ferry-vm needs an ipam section: the hypervisor makes the interface, but something still has to choose its address")
	}

	delegated, err := invoke.DelegateAdd(context.TODO(), conf.IPAM.Type, args.StdinData, nil)
	if err != nil {
		return fmt.Errorf("ipam %s: %w", conf.IPAM.Type, err)
	}
	assigned, err := current.NewResultFromResult(delegated)
	if err != nil {
		return err
	}
	if len(assigned.IPs) == 0 {
		return fmt.Errorf("ipam %s returned no addresses", conf.IPAM.Type)
	}

	// One interface, and it is the pod's NIC inside its own VM. The sandbox is
	// named rather than created: a pod VM's root netns is the sandbox, and it
	// comes into existence when the kernel boots.
	result := &current.Result{
		CNIVersion: conf.CNIVersion,
		Interfaces: []*current.Interface{{
			Name:    args.IfName,
			Sandbox: args.Netns,
		}},
		IPs:    assigned.IPs,
		Routes: assigned.Routes,
		DNS:    assigned.DNS,
	}
	for _, ip := range result.IPs {
		ip.Interface = current.Int(0)
	}
	return types.PrintResult(result, conf.CNIVersion)
}

func cmdDel(args *skel.CmdArgs) error {
	conf, err := parse(args.StdinData)
	if err != nil {
		return err
	}
	if conf.IPAM.Type == "" {
		return nil
	}
	// Releasing the lease is the whole of teardown. The interface goes away
	// when the VM does, which the runtime has already arranged by the time this
	// runs -- and DEL is defined to be idempotent, so a lease that is already
	// gone is a success.
	if err := invoke.DelegateDel(context.TODO(), conf.IPAM.Type, args.StdinData, nil); err != nil {
		return fmt.Errorf("ipam %s: %w", conf.IPAM.Type, err)
	}
	return nil
}

func cmdCheck(args *skel.CmdArgs) error {
	conf, err := parse(args.StdinData)
	if err != nil {
		return err
	}
	if conf.IPAM.Type == "" {
		return nil
	}
	return invoke.DelegateCheck(context.TODO(), conf.IPAM.Type, args.StdinData, nil)
}

func main() {
	skel.PluginMainFuncs(
		skel.CNIFuncs{Add: cmdAdd, Del: cmdDel, Check: cmdCheck},
		version.All,
		"ferry-vm "+buildVersion,
	)
}
