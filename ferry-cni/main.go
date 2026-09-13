// ferry-cni runs real CNI plugins on a Mac.
//
// CNI is a protocol, not a kernel API: JSON on stdin, JSON on stdout, the verb
// in the environment, one process per invocation. Whether a plugin needs Linux
// is a property of that plugin. Upstream's IPAM plugins are pure computation
// and build native Mach-O; the ones that want netlink and a netns do not.
//
// That line falls exactly where ferry already cuts. A main plugin's whole job
// is to make a netns and put an addressed interface in it, and here that is the
// hypervisor -- so ferry does not lack a main plugin, ferry *is* one. What was
// missing is the runtime around it, which is this.
//
// The chain therefore runs in two stages, because Virtualization.framework
// cannot hotplug and the address has to exist before the VM boots:
//
//	stage host    ferry-vm + its IPAM, forked on the Mac, before boot
//	stage guest   the meta chain, shipped into the pod VM and run against its
//	              own root netns, after boot
//
// Nothing configures that split. It is discovered: a plugin runs wherever its
// binary was found, and the two plugin directories hold two architectures.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/containernetworking/cni/libcni"
	"github.com/containernetworking/cni/pkg/types"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "ferry-cni: %v\n", err)
		os.Exit(1)
	}
}

type options struct {
	conflist    string
	containerID string
	netns       string
	ifname      string
	stage       string
	cacheDir    string
	hostDir     string
	guestDir    string
	guestPath   string
	execSocket  string
	execTarget  string
	capArgs     string
	args        string
}

func run(argv []string) error {
	if len(argv) == 0 {
		return errors.New("usage: ferry-cni <add|del|check> [flags]")
	}
	command := argv[0]

	var o options
	fs := flag.NewFlagSet("ferry-cni", flag.ContinueOnError)
	fs.StringVar(&o.conflist, "conflist", "", "path to the CNI configuration list")
	fs.StringVar(&o.containerID, "container-id", "", "CNI_CONTAINERID -- ferry passes the sandbox id")
	fs.StringVar(&o.netns, "netns", "", "CNI_NETNS; inside a pod VM this is its own root netns")
	fs.StringVar(&o.ifname, "ifname", "eth1", "CNI_IFNAME -- the NIC carrying the pod address")
	fs.StringVar(&o.stage, "stage", "all", "which half of the chain to run: host, guest, or all")
	fs.StringVar(&o.cacheDir, "cache-dir", "", "where results are cached between stages and for DEL")
	fs.StringVar(&o.hostDir, "host-plugins", "", "directory of darwin/arm64 plugins, run on the Mac")
	fs.StringVar(&o.guestDir, "guest-plugins", "", "directory of linux/arm64 plugins, as the Mac sees it")
	fs.StringVar(&o.guestPath, "guest-plugin-path", "/opt/cni/bin", "where that directory is mounted inside a pod")
	fs.StringVar(&o.execSocket, "exec-socket", "", "ferry-cri's exec socket, for running a plugin inside a pod")
	fs.StringVar(&o.execTarget, "exec-container", "", "a running container in the pod, to exec the guest plugins in")
	fs.StringVar(&o.capArgs, "capability-args", "", "JSON object of CNI capability arguments, e.g. portMappings")
	fs.StringVar(&o.args, "args", "", "CNI_ARGS, as key=value;key=value")
	if err := fs.Parse(argv[1:]); err != nil {
		return err
	}

	if o.conflist == "" {
		return errors.New("--conflist is required")
	}
	if o.containerID == "" {
		return errors.New("--container-id is required")
	}
	if o.cacheDir == "" {
		o.cacheDir = filepath.Join(filepath.Dir(o.conflist), "cache")
	}

	list, err := libcni.ConfListFromFile(o.conflist)
	if err != nil {
		return fmt.Errorf("read %s: %w", o.conflist, err)
	}

	dispatch := &dispatcher{
		hostDir:    o.hostDir,
		guestDir:   o.guestDir,
		guestPath:  o.guestPath,
		execSocket: o.execSocket,
		execTarget: o.execTarget,
	}
	// The search path is both plugin directories. Which one a plugin is found
	// in decides where it runs, so this is also the stage assignment.
	paths := []string{}
	if o.hostDir != "" {
		paths = append(paths, o.hostDir)
	}
	if o.guestDir != "" {
		paths = append(paths, o.guestDir)
	}
	cni := libcni.NewCNIConfigWithCacheDir(paths, o.cacheDir, dispatch)

	rt := &libcni.RuntimeConf{
		ContainerID: o.containerID,
		NetNS:       o.netns,
		IfName:      o.ifname,
	}
	if o.args != "" {
		for _, pair := range strings.Split(o.args, ";") {
			key, value, found := strings.Cut(pair, "=")
			if !found {
				return fmt.Errorf("malformed --args entry %q, want key=value", pair)
			}
			rt.Args = append(rt.Args, [2]string{key, value})
		}
	}
	if o.capArgs != "" {
		if err := json.Unmarshal([]byte(o.capArgs), &rt.CapabilityArgs); err != nil {
			return fmt.Errorf("--capability-args is not a JSON object: %w", err)
		}
	}

	ctx := context.Background()
	switch command {
	case "add":
		return add(ctx, cni, dispatch, list, rt, o)
	case "del":
		return del(ctx, cni, dispatch, list, rt, o)
	case "check":
		host, guest := split(dispatch, list)
		stage := pick(list, host, guest, o.stage)
		return cni.CheckNetworkList(ctx, stage, rt)
	default:
		return fmt.Errorf("unknown command %q", command)
	}
}

// split divides the chain at the first plugin whose binary is not native to the
// Mac. Everything before it runs here; everything from it on runs in the pod.
//
// A chain that interleaved the two would not be expressible -- the VM boots
// once, between the halves -- so the split is a prefix, and a guest plugin
// appearing before a host plugin is a configuration error worth reporting.
func split(d *dispatcher, list *libcni.NetworkConfigList) (host, guest []*libcni.PluginConfig) {
	inGuest := false
	for _, plugin := range list.Plugins {
		_, err := d.findHost(plugin.Network.Type)
		switch {
		case err == nil && !inGuest:
			host = append(host, plugin)
		default:
			inGuest = true
			guest = append(guest, plugin)
		}
	}
	return host, guest
}

// pick rebuilds a list holding one stage's plugins. Name, version and bytes are
// the whole list's, so the result cache is keyed the same whichever stage wrote
// it -- the cache holds what has actually been done so far, and the last stage
// to run leaves the complete result behind for DEL.
func pick(list *libcni.NetworkConfigList, host, guest []*libcni.PluginConfig, stage string) *libcni.NetworkConfigList {
	out := *list
	switch stage {
	case "host":
		out.Plugins = host
	case "guest":
		out.Plugins = guest
	default:
		out.Plugins = append(append([]*libcni.PluginConfig{}, host...), guest...)
	}
	return &out
}

func add(ctx context.Context, cni libcni.CNI, d *dispatcher, list *libcni.NetworkConfigList,
	rt *libcni.RuntimeConf, o options) error {
	host, guest := split(d, list)
	stage := pick(list, host, guest, o.stage)
	if len(stage.Plugins) == 0 {
		// Nothing to do is not a failure: a conflist with no guest half is a
		// perfectly good one, and ferry calls both stages unconditionally.
		return emit(nil)
	}

	// The guest half continues a chain the host half started, so it needs that
	// result as its prevResult. libcni threads prevResult between plugins in
	// one list but has no way to seed the first, so it is injected into the raw
	// configuration -- which libcni leaves alone when it has nothing of its own
	// to put there.
	if o.stage == "guest" && len(host) > 0 {
		cached, err := cachedResult(cni, list, rt)
		if err != nil {
			return err
		}
		if cached != nil {
			seeded, err := injectPrevResult(stage.Plugins[0], cached)
			if err != nil {
				return err
			}
			plugins := append([]*libcni.PluginConfig{seeded}, stage.Plugins[1:]...)
			stage.Plugins = plugins
		}
	}

	result, err := cni.AddNetworkList(ctx, stage, rt)
	if err != nil {
		return err
	}
	return emit(result)
}

func del(ctx context.Context, cni libcni.CNI, d *dispatcher, list *libcni.NetworkConfigList,
	rt *libcni.RuntimeConf, o options) error {
	host, guest := split(d, list)
	stage := pick(list, host, guest, o.stage)
	if len(stage.Plugins) == 0 {
		return nil
	}
	// DEL is defined to be idempotent, and the guest half can only run while
	// the VM is alive -- so ferry calls it before the pod stops and the host
	// half after. A guest DEL that cannot reach the pod is not fatal: the netns
	// it would have cleaned up went away with the kernel that held it.
	err := cni.DelNetworkList(ctx, stage, rt)
	if err != nil && o.stage == "guest" && errors.Is(err, errPodGone) {
		fmt.Fprintf(os.Stderr, "ferry-cni: pod is gone, skipping the guest half of DEL\n")
		return nil
	}
	return err
}

// cachedResult reads what the host stage left behind for this attachment.
func cachedResult(cni libcni.CNI, list *libcni.NetworkConfigList, rt *libcni.RuntimeConf) (types.Result, error) {
	result, err := cni.GetNetworkListCachedResult(list, rt)
	if err != nil {
		return nil, fmt.Errorf("read the cached result of %s: %w", list.Name, err)
	}
	return result, nil
}

func injectPrevResult(plugin *libcni.PluginConfig, result types.Result) (*libcni.PluginConfig, error) {
	return libcni.InjectConf(plugin, map[string]interface{}{"prevResult": result})
}

// emit prints the result the way a plugin would, so ferry-cri can read the
// address out of it without a second protocol.
func emit(result types.Result) error {
	if result == nil {
		_, err := os.Stdout.WriteString("{}\n")
		return err
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		return err
	}
	_, err = os.Stdout.Write(append(encoded, '\n'))
	return err
}
