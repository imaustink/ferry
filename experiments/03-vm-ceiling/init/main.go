// A Linux init that does nothing but stay alive.
//
// The VM ceiling experiment cares only about how many virtual machines macOS
// will run at once, so the guest needs no userspace beyond something that
// boots, announces itself, and refuses to exit -- a PID 1 that returns panics
// the kernel and would take the VM down with it.
package main

import (
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	if f, err := os.OpenFile("/dev/console", os.O_WRONLY, 0); err == nil {
		fmt.Fprintf(f, "\nferry-vmceiling: guest userspace up\n")
		_ = f.Sync()
	}

	// Reap orphans and ignore termination, the way a real init would; the host
	// stops these VMs at the hypervisor, not by signalling the guest.
	signal.Ignore(syscall.SIGTERM, syscall.SIGINT)
	for {
		time.Sleep(time.Hour)
	}
}
