//go:build linux

// ferry-loop mounts a disk image that reached a running pod VM after it booted.
//
// Virtualization.framework cannot add a disk to a running VM, so a container
// whose image was not attached at boot used to cost the pod its VM. An image
// can still arrive as a file, through the VM's virtiofs share, which ferry-cri
// can grow while the VM runs; what was missing was something in the VM's root
// allowed to put a loop device under it. vminitd has no loop call, and
// nothing in the VM root but vminitd itself, so ferry-cri runs this there as a
// root-of-VM process (Containerization 0.51) with CAP_SYS_ADMIN. Its mount is
// in PID 1's mount namespace, which is where container root filesystems are
// put together (experiments/42-late-disks).
//
//	ferry-loop FILE MOUNTPOINT ro|rw
//
// Prints the loop device. The device is set to autoclear, so unmounting the
// filesystem is all it takes to give the device back, and a VM that stops
// takes every one with it.
//
// Static and linux/arm64, built by 'ferry build' into bin/ferry-loop.
package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"golang.org/x/sys/unix"
)

// readAheadSectors matches what ferry-cri gives a pod's image disks (1 MiB):
// a loop device starts at 128 KiB, a third the throughput on large reads.
const readAheadSectors = 2048

func main() {
	file, mountpoint, readOnly, err := parseArgs(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	device, held, err := attach(file, readOnly)
	if err != nil {
		fail("attach %s: %v", file, err)
	}
	// Held open until the mount has its own reference. The device is
	// autoclear, so closing it first detaches it, and the mount then reads
	// from nothing: EIO.
	defer unix.Close(held)
	if err := os.MkdirAll(mountpoint, 0o755); err != nil {
		fail("mkdir %s: %v", mountpoint, err)
	}
	var flags uintptr
	if readOnly {
		flags = unix.MS_RDONLY
	}
	if err := unix.Mount(device, mountpoint, "ext4", flags, ""); err != nil {
		// Closing the held descriptor, on the way out, detaches it.
		unix.Close(held)
		fail("mount %s on %s: %v", device, mountpoint, err)
	}
	fmt.Println(device)
}

// attach puts file under a free loop device and returns the device's path and
// an open descriptor for it, which the caller holds until the device is in
// use. Retried, because another attach can take the device LOOP_CTL_GET_FREE
// named before this configures it.
func attach(file string, readOnly bool) (string, int, error) {
	openFlags := unix.O_RDWR
	loopFlags := uint32(unix.LO_FLAGS_AUTOCLEAR)
	if readOnly {
		openFlags = unix.O_RDONLY
		loopFlags |= unix.LO_FLAGS_READ_ONLY
	}
	backing, err := unix.Open(file, openFlags|unix.O_CLOEXEC, 0)
	if err != nil {
		return "", -1, err
	}
	defer unix.Close(backing)

	control, err := unix.Open("/dev/loop-control", unix.O_RDWR|unix.O_CLOEXEC, 0)
	if err != nil {
		return "", -1, err
	}
	defer unix.Close(control)

	for attempt := 0; attempt < 8; attempt++ {
		n, err := unix.IoctlRetInt(control, unix.LOOP_CTL_GET_FREE)
		if err != nil {
			return "", -1, fmt.Errorf("LOOP_CTL_GET_FREE: %w", err)
		}
		device := fmt.Sprintf("/dev/loop%d", n)
		fd, err := unix.Open(device, openFlags|unix.O_CLOEXEC, 0)
		if err != nil {
			return "", -1, err
		}
		config := unix.LoopConfig{Fd: uint32(backing)}
		config.Info.Flags = loopFlags
		copy(config.Info.File_name[:], filepath.Base(file))
		err = unix.IoctlLoopConfigure(fd, &config)
		if err != nil {
			unix.Close(fd)
			if errors.Is(err, unix.EBUSY) {
				continue
			}
			return "", -1, fmt.Errorf("LOOP_CONFIGURE %s: %w", device, err)
		}
		_ = unix.IoctlSetInt(fd, unix.BLKRASET, readAheadSectors)
		return device, fd, nil
	}
	return "", -1, errors.New("every free loop device was taken before it could be configured")
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "ferry-loop: "+format+"\n", args...)
	os.Exit(1)
}
