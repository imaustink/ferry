package main

// Volumes, on a kernel with no bind mounts.
//
// The kubelet makes each of a pod's volumes a directory on the node -- an
// emptyDir, a ConfigMap's files, a projected ServiceAccount token -- and asks
// the runtime to put it at a path in the container. A Linux runtime bind-mounts
// it. macOS has no bind mount and no nullfs, a symlink resolves inside the
// chroot, and a directory cannot be hard-linked. What it does have is nfsd.
//
// So the kubelet's pods directory is exported to localhost once, and each
// directory volume is NFS-mounted into the container root: a loopback mount is
// a bind mount by another name. It can be mounted at several paths, so two
// containers of a pod share an emptyDir; writes go straight through; nothing in
// it needs SIP.
//
//	-mapall=root   every client uid is root to the server. A pod's processes
//	               run as uids with no user record, and the kubelet writes what
//	               it projects as root -- a ServiceAccount token is 0600 root --
//	               so without this a pod could not read its own token. It is
//	               the pod's own volumes that are mounted, and a pod's uid cannot
//	               mount anything else.
//	nosuid,nodev   so a volume the pod can write as root is not a way to plant
//	               a setuid binary or a device.
//
// A file the kubelet mounts -- /etc/hosts, /dev/termination-log -- is hard
// linked instead: the same inode, so the kubelet reads what the container
// writes.

import (
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	runtimeapi "k8s.io/cri-api/pkg/apis/runtime/v1"
)

type volumeMount struct {
	host, path string
	readOnly   bool
	file       bool
}

// startNFS exports root to localhost and waits for nfsd to serve it. The
// first start of nfsd on a machine takes a while; a restart does not.
func startNFS(roots []string) ([]string, error) {
	// One line per root: they are on different filesystems -- the kubelet's
	// directory on the node's disk, PersistentVolumes on the Mac's share -- and
	// exports takes one line per filesystem.
	var lines strings.Builder
	for _, root := range roots {
		if err := os.MkdirAll(root, 0o755); err != nil {
			return nil, err
		}
		// 127.0.0.1, not localhost: mountd resolves the host names in exports,
		// and resolving localhost here cost 20 s before the export appeared.
		fmt.Fprintf(&lines, "%s -alldirs -mapall=root 127.0.0.1\n", root)
	}
	if err := os.WriteFile("/etc/exports", []byte(lines.String()), 0o644); err != nil {
		return nil, err
	}
	start := time.Now()
	_ = exec.Command("nfsd", "enable").Run()
	// update if it is running -- the golden image enables it, so it usually
	// is -- and start if not. `nfsd restart` took exactly 20 s here, which is
	// a timeout inside it rather than work.
	verb := "start"
	if out, _ := exec.Command("nfsd", "status").Output(); strings.Contains(string(out), "is running") {
		verb = "update"
	}
	if out, err := exec.Command("nfsd", verb).CombinedOutput(); err != nil {
		return nil, fmt.Errorf("nfsd %s: %v: %s", verb, err, out)
	}
	log.Printf("volumes: nfsd %s took %s", verb, time.Since(start).Round(time.Millisecond))
	// The first root -- the kubelet's -- has to appear; the rest are given a
	// little longer and then left out with a warning, so a PersistentVolume
	// share nfsd will not serve costs PersistentVolumes and nothing else.
	var exported []string
	for time.Since(start) < 60*time.Second {
		out, _ := exec.Command("showmount", "-e", "127.0.0.1").Output()
		exported = exported[:0]
		for _, root := range roots {
			if strings.Contains(string(out), root+" ") || strings.Contains(string(out), root+"\t") || strings.HasSuffix(strings.TrimSpace(string(out)), root) {
				exported = append(exported, root)
			}
		}
		first := len(exported) > 0 && exported[0] == roots[0]
		if len(exported) == len(roots) || (first && time.Since(start) > 25*time.Second) {
			break
		}
		time.Sleep(200 * time.Millisecond)
	}
	if len(exported) == 0 || exported[0] != roots[0] {
		out, _ := exec.Command("showmount", "-e", "127.0.0.1").CombinedOutput()
		return nil, fmt.Errorf("nfsd did not export %s within a minute; it exports: %s", roots[0], strings.TrimSpace(string(out)))
	}
	for _, root := range roots {
		if !contains(exported, root) {
			log.Printf("volumes: nfsd would not export %s; hostPath volumes under it will not mount", root)
		}
	}
	log.Printf("volumes: nfsd exports %s to 127.0.0.1 (%s)", strings.Join(exported, ", "), time.Since(start).Round(time.Millisecond))
	return exported, nil
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// planMounts turns the kubelet's mounts into what this runtime will do with
// each, refusing any it cannot honour rather than starting a container
// without a volume it was promised.
func (r *runtimeSvc) planMounts(mounts []*runtimeapi.Mount) ([]volumeMount, error) {
	var out []volumeMount
	for _, m := range mounts {
		st, err := os.Stat(m.HostPath)
		if err != nil {
			return nil, fmt.Errorf("mount %s: %w", m.HostPath, err)
		}
		v := volumeMount{host: m.HostPath, path: m.ContainerPath, readOnly: m.Readonly, file: !st.IsDir()}
		if !v.file && !r.exported(m.HostPath) {
			return nil, fmt.Errorf("mount %s: only the kubelet's own volumes and PersistentVolumes (under %s) can be mounted on a macOS node", m.HostPath, strings.Join(r.volumesRoots, ", "))
		}
		out = append(out, v)
	}
	// Parents before children, so a volume inside another lands on top of it.
	sort.Slice(out, func(i, j int) bool { return len(out[i].path) < len(out[j].path) })
	return out, nil
}

// devFileDir is where a file the kubelet mounts under /dev lives in a root,
// since /dev itself is devfs and holds no regular files: the file is linked
// here, and a symlink in /dev points at it once devfs is up (linkDevFiles).
const devFileDir = "/.ferry/dev"

// devRel is the part of a container path under /dev, or "" for one elsewhere.
func devRel(p string) string {
	clean := filepath.Clean("/" + p)
	if strings.HasPrefix(clean, "/dev/") {
		return strings.TrimPrefix(clean, "/dev/")
	}
	return ""
}

// mountVolumes puts each volume at its path in the root.
func (r *runtimeSvc) mountVolumes(root string, mounts []volumeMount) error {
	for _, v := range mounts {
		target := filepath.Join(root, filepath.Clean("/"+v.path))
		if rel := devRel(v.path); v.file && rel != "" {
			target = filepath.Join(root, devFileDir, rel)
		}
		if v.file {
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return err
			}
			_ = os.Remove(target)
			if err := os.Link(v.host, target); err != nil {
				return fmt.Errorf("file mount %s: %w", v.path, err)
			}
			continue
		}
		if err := os.MkdirAll(target, 0o755); err != nil {
			return err
		}
		if r.underHostVolumes(v.host) {
			if err := r.pv.mountPV(v.host, target, v.readOnly); err != nil {
				return fmt.Errorf("volume %s: %w", v.path, err)
			}
			continue
		}
		opts := "vers=3,locallocks,nobrowse,nosuid,nodev"
		if v.readOnly {
			opts += ",rdonly"
		}
		if err := run("mount_nfs", "-o", opts, "127.0.0.1:"+v.host, target); err != nil {
			return fmt.Errorf("volume %s: %w", v.path, err)
		}
	}
	return nil
}

// unmountVolumes takes every NFS mount out of a root, deepest first. It has to
// run before the root is removed: removing through a live mount deletes the
// volume's contents on the node.
func unmountVolumes(root string, mounts []volumeMount) {
	for i := len(mounts) - 1; i >= 0; i-- {
		if mounts[i].file {
			continue
		}
		target := filepath.Join(root, filepath.Clean("/"+mounts[i].path))
		if err := exec.Command("umount", target).Run(); err != nil {
			_ = exec.Command("umount", "-f", target).Run()
		}
	}
}

// makeDev gives a root its /dev the way macOS assembles its own: devfs, with
// fdesc union-mounted on top for /dev/fd and /dev/std{in,out,err} --
// `echo x >/dev/stderr` is in half the shell scripts there are.
//
// An ordinary directory of mknod'ed nodes was tried first, so the kubelet's
// /dev/termination-log could be a hard link in it; mount_fdesc refuses any
// mount point that is not devfs, and a /dev without /dev/fd is the worse loss.
func makeDev(dev string) error {
	if err := os.MkdirAll(dev, 0o755); err != nil {
		return err
	}
	if err := run("mount_devfs", "devfs", dev); err != nil {
		return err
	}
	return run("mount_fdesc", "-o", "union", "fdesc", dev)
}

// volumesUp waits for nfsd when a container has a directory volume to mount.
func (r *runtimeSvc) volumesUp(mounts []volumeMount) error {
	need := false
	for _, v := range mounts {
		need = need || !v.file
	}
	if !need || r.nfsReady == nil {
		return nil
	}
	select {
	case <-r.nfsReady:
		return r.nfsErr
	case <-time.After(90 * time.Second):
		return fmt.Errorf("nfsd is not serving volumes yet")
	}
}

// linkDevFiles points /dev/<name> at each file mount devfs cannot hold -- the
// kubelet's /dev/termination-log above all, the file a Job's termination
// message is read from. devfs takes a symlink where it will not take a
// regular file, and the link resolves inside the chroot, so its target is the
// root-relative copy mountVolumes made.
func linkDevFiles(root string, mounts []volumeMount) error {
	for _, v := range mounts {
		rel := devRel(v.path)
		if !v.file || rel == "" {
			continue
		}
		link := filepath.Join(root, "dev", rel)
		_ = os.Remove(link)
		if err := os.Symlink(filepath.Join(devFileDir, rel), link); err != nil {
			return fmt.Errorf("/dev/%s: %w", rel, err)
		}
	}
	return nil
}

// unmountDev takes fdesc and then devfs off a root's /dev: two mounts, one
// on the other, both of which have to go before the root is removed.
func unmountDev(root string) {
	dev := filepath.Join(root, "dev")
	for i := 0; i < 2; i++ {
		if exec.Command("umount", dev).Run() != nil {
			_ = exec.Command("umount", "-f", dev).Run()
		}
	}
}

// underHostVolumes is whether a directory is a PersistentVolume on the Mac's
// share, which the runtime serves itself (pvserve.go).
func (r *runtimeSvc) underHostVolumes(dir string) bool {
	return r.hostVolumes != "" && strings.HasPrefix(filepath.Clean(dir)+"/", r.hostVolumes+"/")
}

// exported is whether a directory can be mounted into a root: under one of
// the roots nfsd serves, or a PersistentVolume the runtime serves.
func (r *runtimeSvc) exported(dir string) bool {
	if r.underHostVolumes(dir) {
		return true
	}
	for _, root := range r.volumesRoots {
		if strings.HasPrefix(filepath.Clean(dir)+"/", root+"/") {
			return true
		}
	}
	return false
}
