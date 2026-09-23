package main

// Which machine each block claim's disk is attached to.
//
// A machine cannot take a device once it has booted -- except a USB disk
// (experiment 26). So a ferry-local-block claim scheduled onto a machine is an
// ext4 image on the Mac, and something has to attach it to the machine the
// pod landed on, before the node image's volume driver can mount it. That is
// this: the Kubernetes attach/detach controller's job, done from the Mac,
// where the disk is.
//
// The channel to ferry-node is the one machines already use: a file in the
// machines directory, <name>.usb, one image path a line. ferry-node makes each
// machine's attached disks match it.
//
// Desired state is read straight off the cluster: every pod bound to a machine
// and not finished, every claim it mounts, and the PersistentVolume behind it
// if that is a ferry.dev/block FlexVolume. A pod that is terminating still
// counts -- the kubelet unmounts its volumes before the pod object goes, so
// detaching only once it has gone is detaching only after the unmount.
//
// One machine at a time per disk, because one ext4 can be mounted by one
// kernel: a disk already listed for a machine stays with it until no pod there
// uses it, and a second machine's pod waits -- its mount keeps failing with a
// message saying so, and the kubelet keeps retrying -- which is what
// ReadWriteOnce means. ferry-node's flock on the volume directory backs this up
// against anything else on the Mac.

import (
	"bytes"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/labels"
	corelisters "k8s.io/client-go/listers/core/v1"
)

const blockDriver = "ferry.dev/block"

type attacher struct {
	pods    corelisters.PodLister
	claims  corelisters.PersistentVolumeClaimLister
	volumes corelisters.PersistentVolumeLister
	// Who is waiting for whose disk, so it is logged when it starts rather
	// than every tick.
	waiting map[string]string
}

func usbFile(name string) string {
	return filepath.Join(*machinesDir, name+".usb")
}

// wanted works out, for each machine, the disk images its pods need.
func (a *attacher) wanted(machines map[string]bool) (map[string][]string, error) {
	pods, err := a.pods.List(labels.Everything())
	if err != nil {
		return nil, err
	}
	want := map[string]map[string]bool{}
	for _, pod := range pods {
		node := pod.Spec.NodeName
		if !machines[node] || pod.Status.Phase == corev1.PodSucceeded || pod.Status.Phase == corev1.PodFailed {
			continue
		}
		for _, v := range pod.Spec.Volumes {
			if v.PersistentVolumeClaim == nil {
				continue
			}
			claim, err := a.claims.PersistentVolumeClaims(pod.Namespace).Get(v.PersistentVolumeClaim.ClaimName)
			if err != nil || claim.Spec.VolumeName == "" {
				continue
			}
			volume, err := a.volumes.Get(claim.Spec.VolumeName)
			if err != nil || volume.Spec.FlexVolume == nil || volume.Spec.FlexVolume.Driver != blockDriver {
				continue
			}
			image := volume.Spec.FlexVolume.Options["image"]
			if image == "" {
				continue
			}
			if want[node] == nil {
				want[node] = map[string]bool{}
			}
			want[node][image] = true
		}
	}
	out := map[string][]string{}
	for node, images := range want {
		for image := range images {
			out[node] = append(out[node], image)
		}
		sort.Strings(out[node])
	}
	return out, nil
}

// leaseHolder is the machine whose volume driver has the image's filesystem
// mounted, from the lease it writes into the volume directory through the
// volumes share, or "" when none has.
func leaseHolder(image string) string {
	data, err := os.ReadFile(filepath.Join(filepath.Dir(image), ".ferry-mounted"))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

// current reads back what each machine's .usb file lists now.
func currentUSB(name string) []string {
	data, err := os.ReadFile(usbFile(name))
	if err != nil {
		return nil
	}
	var out []string
	for _, line := range strings.Split(string(data), "\n") {
		if line = strings.TrimSpace(line); line != "" && !strings.HasPrefix(line, "#") {
			out = append(out, line)
		}
	}
	return out
}

// reconcile rewrites the .usb files so each disk is listed for at most one
// machine: the one already holding it if that one still wants it, and
// otherwise the first to ask, in name order so the answer is stable.
func (a *attacher) reconcile(machines map[string]bool) {
	want, err := a.wanted(machines)
	if err != nil {
		log.Printf("usb: %v", err)
		return
	}
	names := make([]string, 0, len(machines))
	for name := range machines {
		names = append(names, name)
	}
	sort.Strings(names)

	holder := map[string]string{}
	keep := map[string][]string{}
	// Disks stay where they are while they are still wanted there -- or while
	// the machine still has them mounted, which its volume driver says with a
	// lease file beside the image. A pod deleted with --force leaves the API
	// before its kubelet has unmounted anything, and detaching on the pod's
	// disappearance alone pulled disks out from under live mounts: measured,
	// three at once, each an aborted journal in the guest.
	for _, name := range names {
		wanted := map[string]bool{}
		for _, image := range want[name] {
			wanted[image] = true
		}
		for _, image := range currentUSB(name) {
			if (wanted[image] || leaseHolder(image) == name) && holder[image] == "" {
				holder[image] = name
				keep[name] = append(keep[name], image)
			}
		}
	}
	// Then free disks go to whoever asks.
	waiting := map[string]string{}
	for _, name := range names {
		for _, image := range want[name] {
			switch holder[image] {
			case name:
			case "":
				holder[image] = name
				keep[name] = append(keep[name], image)
			default:
				key := name + " " + image
				waiting[key] = holder[image]
				if a.waiting[key] != holder[image] {
					log.Printf("usb: %s waits for %s, which is attached to %s", name, filepath.Base(filepath.Dir(image)), holder[image])
				}
			}
		}
	}
	a.waiting = waiting

	// A machine that has gone lets go of everything, so a later machine that
	// happens to reuse its name does not inherit its disks.
	if stale, err := filepath.Glob(filepath.Join(*machinesDir, "*.usb")); err == nil {
		for _, path := range stale {
			if !machines[strings.TrimSuffix(filepath.Base(path), ".usb")] {
				os.Remove(path)
			}
		}
	}

	for _, name := range names {
		sort.Strings(keep[name])
		var body bytes.Buffer
		for _, image := range keep[name] {
			body.WriteString(image + "\n")
		}
		path := usbFile(name)
		old, _ := os.ReadFile(path)
		if bytes.Equal(old, body.Bytes()) {
			continue
		}
		if body.Len() == 0 {
			os.Remove(path)
		} else if err := writeAtomic(path, body.Bytes()); err != nil {
			log.Printf("usb: %s: %v", name, err)
			continue
		}
		log.Printf("usb: %s now holds %d disk(s)", name, len(keep[name]))
	}
}

func writeAtomic(path string, data []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
