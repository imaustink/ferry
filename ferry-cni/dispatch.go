package main

// The seam.
//
// libcni reaches plugins through an interface it documents as substitutable:
//
//	type Exec interface {
//		ExecPlugin(ctx, pluginPath string, stdinData []byte, environ []string) ([]byte, error)
//		FindInPath(plugin string, paths []string) (string, error)
//		Decode(jsonBytes []byte) (version.PluginInfo, error)
//	}
//
// This is the same shape as the kube-proxy seam: there the proxier talked to a
// knftables.Interface and ferry supplied a renderer instead of a kernel. Here
// the runtime talks to an invoke.Exec and ferry supplies a *dispatching*
// implementation -- fork a Mach-O plugin on the Mac, ship an ELF one into the
// pod VM and exec it there.
//
// Neither half is a special case in the protocol. Both get JSON on stdin, the
// verb in the environment, and JSON back on stdout.

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/containernetworking/cni/pkg/invoke"
	"github.com/containernetworking/cni/pkg/version"
)

// errPodGone says the pod VM could not be reached, which on DEL is not an error
// -- the netns went away with the kernel that held it.
var errPodGone = errors.New("the pod is not running")

type dispatcher struct {
	// Where darwin/arm64 plugins live on the Mac.
	hostDir string
	// Where linux/arm64 plugins live on the Mac -- the directory ferry-cri
	// shares into every pod.
	guestDir string
	// Where that same directory appears inside a pod.
	guestPath string
	// ferry-cri's exec socket, the only way into a running pod's VM.
	execSocket string
	// A running container in the target pod. A pod is one VM and one network
	// stack, so any of its containers is the same netns -- this just names a
	// process tree to exec beside.
	execTarget string
}

// findHost reports whether a plugin is native to the Mac, and where.
func (d *dispatcher) findHost(plugin string) (string, error) {
	if d.hostDir == "" {
		return "", fmt.Errorf("no host plugin directory configured")
	}
	return invoke.FindInPath(plugin, []string{d.hostDir})
}

// FindInPath is part of invoke.Exec. Both plugin directories are on the Mac, so
// the lookup is ordinary -- it is ExecPlugin that cares which one won.
func (d *dispatcher) FindInPath(plugin string, paths []string) (string, error) {
	return invoke.FindInPath(plugin, paths)
}

// Decode is part of invoke.Exec: the version handshake, which is plain JSON and
// the same wherever the plugin ran.
func (d *dispatcher) Decode(jsonBytes []byte) (version.PluginInfo, error) {
	decoder := &version.PluginDecoder{}
	return decoder.Decode(jsonBytes)
}

// ExecPlugin is part of invoke.Exec, and is the whole dispatch.
func (d *dispatcher) ExecPlugin(ctx context.Context, pluginPath string, stdinData []byte, environ []string) ([]byte, error) {
	if d.guestDir != "" && underDir(pluginPath, d.guestDir) {
		// A Linux binary. It cannot run here, and it does not need to: the pod
		// has a kernel of its own and this directory is already mounted in it.
		guest := filepath.Join(d.guestPath, filepath.Base(pluginPath))
		return d.execInPod(ctx, guest, stdinData, environ)
	}
	// A Mach-O binary. Fork it the way any CNI runtime would.
	raw := invoke.RawExec{Stderr: os.Stderr}
	return raw.ExecPlugin(ctx, pluginPath, stdinData, environ)
}

func underDir(path, dir string) bool {
	absPath, err := filepath.Abs(path)
	if err != nil {
		return false
	}
	absDir, err := filepath.Abs(dir)
	if err != nil {
		return false
	}
	rel, err := filepath.Rel(absDir, absPath)
	if err != nil {
		return false
	}
	return rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}
