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

// Host filesystem queries on macOS. Most of this interface is ordinary stat
// work and behaves exactly as it does on Linux. The exceptions are the two
// concepts macOS has no equivalent of -- shared mount propagation and SELinux
// -- which report absence rather than an error, because the kubelet treats an
// error here as a fatal node condition while it handles "not supported"
// perfectly well.
package hostutil

import (
	"os"
	"path/filepath"
	"syscall"

	"k8s.io/klog/v2"
	"k8s.io/mount-utils"
)

type HostUtil struct{}

var _ HostUtils = &HostUtil{}

func NewHostUtil() *HostUtil {
	return &HostUtil{}
}

// DeviceOpened reports whether a device is in use by something other than the
// caller. macOS exposes no equivalent of scanning /proc/*/mounts for this, and
// the pod-per-VM model never attaches raw block devices to the host, so nothing
// is ever considered opened.
func (hu *HostUtil) DeviceOpened(pathname string) (bool, error) {
	return false, nil
}

func (hu *HostUtil) PathIsDevice(pathname string) (bool, error) {
	t, err := hu.GetFileType(pathname)
	if err != nil {
		return false, err
	}
	return t == FileTypeBlockDev || t == FileTypeCharDev, nil
}

// MakeRShared would mark a mount point rshared so that mounts made inside a
// container propagate back to the host. macOS has no mount propagation, and
// nothing in this runtime depends on it: guest mounts happen inside the VM.
func (hu *HostUtil) MakeRShared(path string) error {
	klog.V(4).InfoS("Mount propagation is not available on darwin; ignoring rshared request", "path", path)
	return nil
}

func (hu *HostUtil) GetFileType(pathname string) (FileType, error) {
	return getFileType(pathname)
}

func (hu *HostUtil) PathExists(pathname string) (bool, error) {
	return mount.PathExists(pathname)
}

func (hu *HostUtil) EvalHostSymlinks(pathname string) (string, error) {
	return filepath.EvalSymlinks(pathname)
}

func (hu *HostUtil) GetOwner(pathname string) (int64, int64, error) {
	realpath, err := filepath.EvalSymlinks(pathname)
	if err != nil {
		return -1, -1, err
	}
	info, err := os.Stat(realpath)
	if err != nil {
		return -1, -1, err
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return -1, -1, nil
	}
	return int64(st.Uid), int64(st.Gid), nil
}

func (hu *HostUtil) GetSELinuxSupport(pathname string) (bool, error) {
	return false, nil
}

func (hu *HostUtil) GetMode(pathname string) (os.FileMode, error) {
	info, err := os.Stat(pathname)
	if err != nil {
		return 0, err
	}
	return info.Mode(), nil
}

func (hu *HostUtil) GetSELinuxMountContext(pathname string) (string, error) {
	return "", nil
}

// getDeviceNameFromMount resolves the device backing a mount path. Volumes in
// this runtime are attached inside the guest VM rather than mounted on the
// host, so the host never has a device name to report. Returning empty with no
// error matches how callers treat an unmounted path.
func getDeviceNameFromMount(mounter mount.Interface, mountPath, pluginMountDir string) (string, error) {
	return "", nil
}
