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
//	ferry-loop attach FILE ro|rw N
//	ferry-loop rm DIR
//
// The first mounts an image and prints the loop device, set to autoclear, so
// unmounting the filesystem gives the device back. attach puts FILE under
// /dev/loopN without mounting it, for the guest agent to mount (a late
// volume, through LinuxPod.attachVolume). rm deletes a directory beneath
// /run/volumes/: a removed container's upper directory on the scratch disk,
// which the guest agent has no call to delete.
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
	cmd, err := parseCommand(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	switch cmd.op {
	case "rm":
		// RemoveAll opens each directory with O_NOFOLLOW and unlinks beneath
		// it, so a symlink the container left in its upper directory is
		// removed, never followed.
		if err := os.RemoveAll(cmd.target); err != nil {
			fail("rm %s: %v", cmd.target, err)
		}
	case "attach":
		device, err := attachAt(cmd.file, cmd.readOnly, cmd.device)
		if err != nil {
			fail("attach %s: %v", cmd.file, err)
		}
		fmt.Println(device)
	default:
		mount(cmd)
	}
}

func mount(cmd command) {
	device, held, err := attach(cmd.file, cmd.readOnly)
	if err != nil {
		fail("attach %s: %v", cmd.file, err)
	}
	// Held open until the mount has its own reference. The device is
	// autoclear, so closing it first detaches it, and the mount then reads
	// from nothing: EIO.
	defer unix.Close(held)
	if err := os.MkdirAll(cmd.target, 0o755); err != nil {
		fail("mkdir %s: %v", cmd.target, err)
	}
	var flags uintptr
	if cmd.readOnly {
		flags = unix.MS_RDONLY
	}
	if err := unix.Mount(device, cmd.target, "ext4", flags, ""); err != nil {
		// Closing the held descriptor, on the way out, detaches it.
		unix.Close(held)
		fail("mount %s on %s: %v", device, cmd.target, err)
	}
	fmt.Println(device)
}

// attachAt puts file under /dev/loopN, a number the caller chose so that it
// knows the device without reading this process's output, and leaves it
// unmounted for the guest agent to mount (LinuxPod.attachVolume). Not
// autoclear: nothing holds the device between this exiting and that mount.
// It stays attached until the VM stops, and LinuxPod.stop unmounts the
// filesystem on it first.
func attachAt(file string, readOnly bool, n int) (string, error) {
	openFlags := unix.O_RDWR
	var loopFlags uint32
	if readOnly {
		openFlags = unix.O_RDONLY
		loopFlags |= unix.LO_FLAGS_READ_ONLY
	}
	backing, err := unix.Open(file, openFlags|unix.O_CLOEXEC, 0)
	if err != nil {
		return "", err
	}
	defer unix.Close(backing)
	control, err := unix.Open("/dev/loop-control", unix.O_RDWR|unix.O_CLOEXEC, 0)
	if err != nil {
		return "", err
	}
	defer unix.Close(control)
	// LOOP_CTL_ADD makes /dev/loopN, and devtmpfs its node. EEXIST is a
	// device that is already there, which is fine if it is free: the
	// configure below says EBUSY if it is not.
	if _, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(control), unix.LOOP_CTL_ADD, uintptr(n)); errno != 0 &&
		errno != unix.EEXIST {
		return "", fmt.Errorf("LOOP_CTL_ADD %d: %w", n, errno)
	}
	device := fmt.Sprintf("/dev/loop%d", n)
	fd, err := unix.Open(device, openFlags|unix.O_CLOEXEC, 0)
	if err != nil {
		return "", err
	}
	defer unix.Close(fd)
	config := unix.LoopConfig{Fd: uint32(backing)}
	config.Info.Flags = loopFlags
	copy(config.Info.File_name[:], filepath.Base(file))
	if err := unix.IoctlLoopConfigure(fd, &config); err != nil {
		return "", fmt.Errorf("LOOP_CONFIGURE %s: %w", device, err)
	}
	_ = unix.IoctlSetInt(fd, unix.BLKRASET, readAheadSectors)
	return device, nil
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
