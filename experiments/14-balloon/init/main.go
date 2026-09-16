// A Linux init that uses memory, gives it back, and says what the guest thinks
// it has.
//
// The balloon question is whether memory handed to a pod VM can be taken back
// afterwards. That needs a guest which has actually touched its allowance --
// lazily-backed memory nobody wrote to costs the host nothing and would make
// any reclaim look free -- and which then reports what the kernel believes it
// owns, so the host can tell a balloon that inflated from one that was ignored.
package main

import (
	"fmt"
	"os"
	"runtime"
	"runtime/debug"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// touchMiB is read from the kernel command line (ferry.touch=N), so the host
// decides how much the guest dirties without rebuilding the initramfs.
func touchMiB() int {
	body, err := os.ReadFile("/proc/cmdline")
	if err != nil {
		return 0
	}
	for _, field := range strings.Fields(string(body)) {
		if rest, ok := strings.CutPrefix(field, "ferry.touch="); ok {
			n, err := strconv.Atoi(rest)
			if err == nil {
				return n
			}
		}
	}
	return 0
}

// meminfo returns MemTotal and MemFree in MiB. MemTotal is the interesting one:
// Linux's virtio_balloon adjusts the managed page count as it inflates, so a
// falling MemTotal is the guest agreeing it has less memory than it started
// with -- proof the request was honoured rather than merely sent.
func meminfo() (total, free int) {
	body, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return 0, 0
	}
	for _, line := range strings.Split(string(body), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		kib, err := strconv.Atoi(fields[1])
		if err != nil {
			continue
		}
		switch fields[0] {
		case "MemTotal:":
			total = kib / 1024
		case "MemFree:":
			free = kib / 1024
		}
	}
	return total, free
}

func main() {
	// The initramfs is one file, so the mount point has to be made here before
	// there is anywhere to mount procfs onto — and without procfs this guest
	// cannot read its own command line or its own memory, which is everything
	// it is here to do.
	_ = os.Mkdir("/proc", 0o555)
	_ = syscall.Mount("proc", "/proc", "proc", 0, "")
	_ = os.Mkdir("/sys", 0o555)
	_ = syscall.Mount("sysfs", "/sys", "sysfs", 0, "")

	console, err := os.OpenFile("/dev/console", os.O_WRONLY, 0)
	if err != nil {
		console = os.Stdout
	}
	say := func(format string, args ...any) {
		fmt.Fprintf(console, format+"\n", args...)
		_ = console.Sync()
	}

	say("")
	say("ferry-balloon: guest userspace up")

	// Which virtio devices the guest found, and whether anything is driving
	// them. virtio device id 5 is the traditional memory balloon; a balloon
	// that is present but unbound explains a host request that changes nothing
	// just as well as a balloon that was never offered, and the two want
	// different fixes.
	if entries, err := os.ReadDir("/sys/bus/virtio/devices"); err == nil {
		for _, entry := range entries {
			base := "/sys/bus/virtio/devices/" + entry.Name()
			id, _ := os.ReadFile(base + "/device")
			driver := "none"
			if link, err := os.Readlink(base + "/driver"); err == nil {
				driver = link[strings.LastIndex(link, "/")+1:]
			}
			say("ferry-balloon: virtio %s device=%s driver=%s",
				entry.Name(), strings.TrimSpace(string(id)), driver)
		}
	} else {
		say("ferry-balloon: no /sys/bus/virtio/devices (%v)", err)
	}

	if mib := touchMiB(); mib > 0 {
		// Write a byte to every page: anything less and the host never backs
		// the pages, which is the whole thing being measured.
		block := make([]byte, mib*1024*1024)
		for i := 0; i < len(block); i += 4096 {
			block[i] = 1
		}
		total, free := meminfo()
		say("ferry-balloon: touched %d MiB (MemTotal %d, MemFree %d)", mib, total, free)

		// Hand it back to the guest kernel. The pages are now free inside the
		// guest but still backed on the host -- exactly the state a pod is in
		// after a burst, and exactly what a balloon is supposed to recover.
		block = nil
		runtime.GC()
		debug.FreeOSMemory()
		total, free = meminfo()
		say("ferry-balloon: released (MemTotal %d, MemFree %d)", total, free)
	}

	say("ferry-balloon: steady")
	for {
		total, free := meminfo()
		say("ferry-balloon: meminfo MemTotal=%d MemFree=%d", total, free)
		time.Sleep(2 * time.Second)
	}
}
