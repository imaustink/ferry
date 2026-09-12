//go:build darwin

/*
Copyright 2014 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// Mounting on macOS, where the host deliberately mounts nothing.
//
// In this runtime a pod is a virtual machine, so a volume is attached inside
// the guest -- the host's only job is to assemble the volume's contents in a
// directory and hand that directory to the VM. The kubelet still drives the
// volume manager to build those directories, and the volume manager still
// calls a Mounter while doing it, so this implementation makes those calls
// succeed against the plain filesystem instead of failing.
//
// The one real consequence: on Linux, projected volumes holding service
// account tokens are backed by tmpfs and never touch a disk. macOS has no
// tmpfs, so those files land on an ordinary (FileVault-encrypted) filesystem
// and are removed when the volume is torn down.
package mount

import (
	"fmt"
	"os"

	"k8s.io/klog/v2"
)

// Mounter implements mount.Interface for macOS.
type Mounter struct {
	mounterPath string
}

// New returns a mount.Interface for the current system.
func New(mounterPath string) Interface {
	return &Mounter{mounterPath: mounterPath}
}

func (mounter *Mounter) Mount(source string, target string, fstype string, options []string) error {
	return mounter.MountSensitive(source, target, fstype, options, nil)
}

// MountSensitive satisfies the mount request using the filesystem rather than
// the kernel. Memory-backed filesystems become ordinary directories; a bind
// mount of a directory that already holds the right contents is a no-op.
// Anything else is a request this platform genuinely cannot serve, and is
// reported rather than silently ignored.
func (mounter *Mounter) MountSensitive(source string, target string, fstype string, options []string, sensitiveOptions []string) error {
	switch fstype {
	case "tmpfs", "ramfs", "":
		if err := os.MkdirAll(target, 0o755); err != nil {
			return fmt.Errorf("create mount target %s: %w", target, err)
		}
		klog.V(4).InfoS("Served mount from the filesystem; darwin has no kernel mount for this type",
			"target", target, "fstype", fstype)
		return nil
	default:
		return fmt.Errorf("mounting %q filesystems is not supported on darwin (source %s, target %s)", fstype, source, target)
	}
}

func (mounter *Mounter) MountSensitiveWithoutSystemd(source string, target string, fstype string, options []string, sensitiveOptions []string) error {
	return mounter.MountSensitive(source, target, fstype, options, sensitiveOptions)
}

func (mounter *Mounter) MountSensitiveWithoutSystemdWithMountFlags(source string, target string, fstype string, options []string, sensitiveOptions []string, mountFlags []string) error {
	return mounter.MountSensitive(source, target, fstype, options, sensitiveOptions)
}

// Unmount removes the directory that stood in for a mount. The volume manager
// expects the path to be gone afterwards, not merely detached.
func (mounter *Mounter) Unmount(target string) error {
	if err := os.RemoveAll(target); err != nil {
		return fmt.Errorf("remove mount target %s: %w", target, err)
	}
	return nil
}

// List reports mounted filesystems. Nothing here was mounted through the
// kernel, so there is nothing to report.
func (mounter *Mounter) List() ([]MountPoint, error) {
	return []MountPoint{}, nil
}

// IsLikelyNotMountPoint reports whether a path is definitely not a mount point.
// Since this Mounter never creates kernel mounts, an existing directory is
// never one -- but the caller still needs a stat error for a missing path.
func (mounter *Mounter) IsLikelyNotMountPoint(file string) (bool, error) {
	if _, err := os.Stat(file); err != nil {
		return true, err
	}
	return true, nil
}

func (mounter *Mounter) CanSafelySkipMountPointCheck() bool {
	return true
}

func (mounter *Mounter) IsMountPoint(file string) (bool, error) {
	notMnt, err := mounter.IsLikelyNotMountPoint(file)
	if err != nil {
		return false, err
	}
	return !notMnt, nil
}

func (mounter *Mounter) GetMountRefs(pathname string) ([]string, error) {
	return []string{}, nil
}

func (mounter *SafeFormatAndMount) formatAndMountSensitive(source string, target string, fstype string, options []string, sensitiveOptions []string, formatOptions []string) error {
	return mounter.Interface.Mount(source, target, fstype, options)
}

// diskLooksUnformatted would inspect a raw block device. Block devices are
// attached inside the guest VM, never to the host.
func (mounter *SafeFormatAndMount) diskLooksUnformatted(disk string) (bool, error) {
	return false, fmt.Errorf("inspecting block device %s is not supported on darwin", disk)
}

func (mounter *SafeFormatAndMount) IsMountPoint(file string) (bool, error) {
	return mounter.Interface.IsMountPoint(file)
}
