package main

// The node's side of a pod: the OS files every container root links to, the
// pod's address, and the pf rules that keep an address to its own pod.
//
// Darwin has no namespaces, so none of this is a boundary the kernel draws
// around a pod the way Linux draws one around a network namespace. It is the
// set experiment 39 found that does add up to one:
//
//	a private /        chroot, into a root of hard links (needs SIP off)
//	a private address  an alias on the node's interface, a loopback route,
//	                   and podnet.dylib rewriting wildcard binds onto it
//	enforcement        pf `user` rules: an address carries traffic only for
//	                   sockets owned by its pod's uid
//	separation         a uid per pod, so pods cannot signal or read each other

import (
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// The OS a container runs on, as dyld inside a chroot needs it: the dynamic
// linker, and the shared cache at the path dyld looks for it relative to its
// root. The cache is 6.2 GB and is copied once, into the node's state; every
// container root after that is hard links to the same inodes.
const (
	cacheSource = "/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld"
	cacheInRoot = "System/Library/dyld"
	dyldInRoot  = "usr/lib/dyld"
	shimInRoot  = "lib/podnet.dylib"
)

type node struct {
	state string // runtime state: os/, images/, pods/
	iface string // where pod addresses are aliased
	base  net.IP // standalone: the node's own address; pods take .200 and up in its /24
	shim  string

	// On ferry's pod network instead: the card on the pod switch, the
	// cluster's CIDR, and this node's slice of it, which the kubelet hands
	// over in UpdateRuntimeConfig once kube-controller-manager has chosen it.
	// The card takes the slice's .1 with the cluster's prefix -- a Linux
	// machine's eth1 arrangement -- so every pod on the segment treats this
	// node as on-link, and each pod's address, an alias on the card, answers
	// ARP for itself.
	clusterCIDR *net.IPNet
	slice       *net.IPNet

	// podVM is a machine that is one pod's VM: the pod runs as root. A uid of
	// its own is what keeps pods sharing a kernel apart, and here there is no
	// other pod -- the kubelet schedules one -- so it would only keep the pod
	// from the things a VM of its own is for: sudo-shaped CI steps,
	// installers, system settings.
	podVM bool

	mu    sync.Mutex
	pods  map[string]podAddr // sandbox id -> its address and uid
	nextN int
}

// localAddr is the node's own address on the network its pods are on, to
// connect to a pod from. Left to itself the kernel picks the pod's alias as
// the source of a connection to it, and pf then refuses the packet: that
// address carries traffic only for the pod's uid, and the runtime is root.
func (n *node) localAddr() net.IP {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.slice != nil {
		s := n.slice.IP.To4()
		return net.IPv4(s[0], s[1], s[2], s[3]+1)
	}
	return n.base
}

// networkReady is whether a pod can be given an address yet.
func (n *node) networkReady() bool {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.clusterCIDR == nil || n.slice != nil
}

// setPodCIDR takes the node's slice and puts its .1 on the pod card.
func (n *node) setPodCIDR(cidr string) error {
	if n.clusterCIDR == nil || cidr == "" {
		return nil
	}
	_, slice, err := net.ParseCIDR(cidr)
	if err != nil {
		return err
	}
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.slice != nil && n.slice.String() == slice.String() {
		return nil
	}
	gw := slice.IP.To4()
	gw = net.IPv4(gw[0], gw[1], gw[2], gw[3]+1)
	mask := net.IP(n.clusterCIDR.Mask).String()
	if err := run("ifconfig", n.iface, "inet", gw.String(), "netmask", mask, "up"); err != nil {
		return err
	}
	// The weak host model, which Linux has by default and macOS here did not
	// (check_interface=1): a packet is accepted for an address on any of the
	// node's cards, not only the card that holds it. Pods' addresses are on the
	// pod card, and a Linux machine reaches them by the machine network -- its
	// route agent routes this node's slice via this node's machine address --
	// so with the check on, a Linux machine's SYN arrived on the machine card
	// and was dropped before anything saw it. pf's rules still decide what an
	// address accepts, whichever card it came in by.
	if err := run("sysctl", "-w", "net.inet.ip.check_interface=0"); err != nil {
		return err
	}
	n.slice = slice
	log.Printf("node: pod network %s on %s as %s/%s", slice, n.iface, gw, mask)
	return nil
}

type podAddr struct {
	ip  string
	uid int
}

func newNode(state, iface, shim, clusterCIDR string) (*node, error) {
	n := &node{state: state, iface: iface, shim: shim, pods: map[string]podAddr{}}
	for _, d := range []string{"os", "images", "pods"} {
		if err := os.MkdirAll(filepath.Join(state, d), 0o755); err != nil {
			return nil, err
		}
	}
	if clusterCIDR != "" {
		_, cc, err := net.ParseCIDR(clusterCIDR)
		if err != nil {
			return nil, err
		}
		n.clusterCIDR = cc
	} else {
		addr, err := ifaceAddr(iface)
		if err != nil {
			return nil, err
		}
		n.base = addr
	}
	if err := n.prepareOS(); err != nil {
		return nil, err
	}
	if err := n.startPF(); err != nil {
		return nil, err
	}
	return n, nil
}

func ifaceAddr(name string) (net.IP, error) {
	ifc, err := net.InterfaceByName(name)
	if err != nil {
		return nil, err
	}
	addrs, err := ifc.Addrs()
	if err != nil {
		return nil, err
	}
	for _, a := range addrs {
		if ipn, ok := a.(*net.IPNet); ok && ipn.IP.To4() != nil {
			return ipn.IP.To4(), nil
		}
	}
	return nil, fmt.Errorf("%s has no IPv4 address", name)
}

// prepareOS copies dyld and the shared cache into state/os once.
func (n *node) prepareOS() error {
	osRoot := filepath.Join(n.state, "os")
	// The shim is the runtime's, not the OS's: copied on every start, so a
	// new shim reaches pods without the 6 GB copy below being redone. It was
	// once copied only with the cache, and a golden image updated in place
	// kept serving pods the shim it was first baked with.
	if n.shim != "" {
		if err := copyFile(n.shim, filepath.Join(osRoot, shimInRoot), 0o755); err != nil {
			return err
		}
	}
	if err := n.prepareTools(osRoot); err != nil {
		return err
	}
	marker := filepath.Join(osRoot, ".complete")
	if _, err := os.Stat(marker); err == nil {
		return nil
	}
	log.Printf("node: copying dyld and the shared cache into %s (once)", osRoot)
	if err := copyFile("/usr/lib/dyld", filepath.Join(osRoot, dyldInRoot), 0o755); err != nil {
		return err
	}
	entries, err := os.ReadDir(cacheSource)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if err := copyFile(filepath.Join(cacheSource, e.Name()), filepath.Join(osRoot, cacheInRoot, e.Name()), 0o755); err != nil {
			return err
		}
	}
	return os.WriteFile(marker, nil, 0o644)
}

// osTools are the OS's command-line tools every pod root carries, beside dyld
// and the cache: 4 MB of /bin and 80 MB of /usr/bin on macOS 26, once per
// image. An image cannot ship Apple's binaries -- a copy outside the OS is
// killed where SIP is on -- but on a node with SIP off a copy runs, so the
// node provides them, the way it provides libSystem. A pod has a shell to
// `kubectl exec` into. The image's own files win where the names meet.
var osTools = []string{"/bin", "/usr/bin", "/usr/share/terminfo",
	// sysctl, ifconfig, mount: a pod's VM runs its pod as root, and root wants them.
	"/sbin", "/usr/sbin",
	// What sw_vers, and anything else asking which macOS this is, reads.
	"/System/Library/CoreServices/SystemVersion.plist",
	// The CA bundle curl and LibreSSL look for; /etc is linked to it below.
	"/private/etc/ssl"}

func (n *node) prepareTools(osRoot string) error {
	marker := filepath.Join(osRoot, ".tools-4")
	if _, err := os.Stat(marker); err == nil {
		return nil
	}
	start := time.Now()
	for _, dir := range osTools {
		err := filepath.Walk(dir, func(p string, info os.FileInfo, err error) error {
			if err != nil {
				return nil // a file the OS will not let root read is one pods do without
			}
			dst := filepath.Join(osRoot, p)
			switch {
			case info.IsDir():
				return os.MkdirAll(dst, 0o755)
			case info.Mode()&os.ModeSymlink != 0:
				link, err := os.Readlink(p)
				if err == nil {
					_ = os.Remove(dst)
					_ = os.Symlink(link, dst)
				}
				return nil
			case info.Mode().IsRegular():
				_ = copyFile(p, dst, info.Mode().Perm())
			}
			return nil
		})
		if err != nil {
			return err
		}
	}
	// /etc is a link to /private/etc on macOS, and tools ask for both.
	_ = os.Remove(filepath.Join(osRoot, "etc"))
	_ = os.Symlink("private/etc", filepath.Join(osRoot, "etc"))
	log.Printf("node: %s copied into the OS base in %s", strings.Join(osTools, ", "), time.Since(start).Round(time.Millisecond))
	return os.WriteFile(marker, nil, 0o644)
}

func copyFile(src, dst string, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	// A new file renamed into place, never the old one truncated: what is
	// here is hard-linked into container roots, and rewriting that inode would
	// rewrite a library under a running pod.
	tmp := dst + ".new"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, dst)
}

// linkTree hard-links every file under src into dst, making directories as it
// goes. Both are on the node's data volume, so a root costs inodes, not blocks.
func linkTree(src, dst string) error {
	return filepath.Walk(src, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		if base := filepath.Base(rel); rel == "." || base == ".complete" || strings.HasPrefix(base, ".tools") {
			return nil
		}
		target := filepath.Join(dst, rel)
		if !info.IsDir() {
			// A later tree wins: the image's files over the OS base's.
			_ = os.Remove(target)
		}
		switch {
		case info.IsDir():
			return os.MkdirAll(target, 0o755)
		case info.Mode()&os.ModeSymlink != 0:
			link, err := os.Readlink(p)
			if err != nil {
				return err
			}
			return os.Symlink(link, target)
		default:
			return os.Link(p, target)
		}
	})
}

// allocate gives a sandbox its address and uid, and puts the address on the
// node: an alias on the interface so the network reaches it, and a host route
// through loopback so the node itself does -- without it the node sends
// traffic for its own alias out of the interface, and the network does not
// hairpin it back.
func (n *node) allocate(id string) (podAddr, error) {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.nextN++
	var a podAddr
	if n.clusterCIDR != nil {
		// .1 is the card's own; pods are .2 and up. No reuse: a prototype.
		if n.slice == nil {
			return podAddr{}, fmt.Errorf("no pod CIDR yet")
		}
		if n.nextN > 250 {
			return podAddr{}, fmt.Errorf("pod CIDR %s exhausted", n.slice)
		}
		s := n.slice.IP.To4()
		a = podAddr{ip: fmt.Sprintf("%d.%d.%d.%d", s[0], s[1], s[2], 1+n.nextN), uid: 1000 + n.nextN}
	} else {
		if n.nextN > 50 {
			return podAddr{}, fmt.Errorf("prototype address range exhausted")
		}
		b := n.base
		a = podAddr{ip: fmt.Sprintf("%d.%d.%d.%d", b[0], b[1], b[2], 199+n.nextN), uid: 1000 + n.nextN}
	}
	if n.podVM {
		a.uid = 0
	}
	if err := run("ifconfig", n.iface, "alias", a.ip, "255.255.255.255"); err != nil {
		return podAddr{}, err
	}
	_ = run("route", "-q", "-n", "add", "-host", a.ip, "-interface", "lo0")
	n.pods[id] = a
	return a, n.writePF()
}

func (n *node) release(id string) {
	n.mu.Lock()
	defer n.mu.Unlock()
	a, ok := n.pods[id]
	if !ok {
		return
	}
	delete(n.pods, id)
	_ = run("route", "-q", "-n", "delete", "-host", a.ip)
	_ = run("ifconfig", n.iface, "-alias", a.ip)
	_ = n.writePF()
}

// startPF loads a main ruleset that passes everything but defers to the
// "ferry" anchor first, and enables pf. The node is a disposable VM, so the
// system's own ruleset is not kept.
func (n *node) startPF() error {
	main := filepath.Join(n.state, "pf.conf")
	if err := os.WriteFile(main, []byte("anchor \"ferry\"\npass all\n"), 0o644); err != nil {
		return err
	}
	_ = exec.Command("pfctl", "-q", "-E").Run()
	if err := run("pfctl", "-q", "-f", main); err != nil {
		return err
	}
	return n.writePF()
}

func (n *node) writePF() error {
	var ids []string
	for id := range n.pods {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	var b strings.Builder
	for _, id := range ids {
		a := n.pods[id]
		fmt.Fprintf(&b, "block return in  quick proto { tcp udp } to %s user != %d\n", a.ip, a.uid)
		fmt.Fprintf(&b, "block return out quick proto { tcp udp } from %s user != %d\n", a.ip, a.uid)
	}
	f := filepath.Join(n.state, "pf.anchor")
	if err := os.WriteFile(f, []byte(b.String()), 0o644); err != nil {
		return err
	}
	return run("pfctl", "-q", "-a", "ferry", "-f", f)
}

func run(name string, args ...string) error {
	out, err := exec.Command(name, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %s: %v: %s", name, strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return nil
}
