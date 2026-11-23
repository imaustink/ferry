// fsyncbench: N 4 KiB writes to one file, each followed by fdatasync (or not),
// in one process, so process start-up is not in the figure.
//
//	fsyncbench FILE N sync|nosync
package main

import (
	"fmt"
	"os"
	"strconv"
	"syscall"
	"time"
)

func main() {
	if len(os.Args) == 4 && os.Args[1] == "counter" {
		counter(os.Args[2], os.Args[3])
		return
	}
	if len(os.Args) != 4 {
		fmt.Fprintln(os.Stderr, "usage: fsyncbench FILE N sync|nosync")
		os.Exit(2)
	}
	n, err := strconv.Atoi(os.Args[2])
	if err != nil || n < 1 {
		fmt.Fprintln(os.Stderr, "bad N")
		os.Exit(2)
	}
	sync := os.Args[3] == "sync"
	f, err := os.OpenFile(os.Args[1], os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		fmt.Println("open:", err)
		os.Exit(1)
	}
	buf := make([]byte, 4096)
	start := time.Now()
	for i := 0; i < n; i++ {
		buf[0] = byte(i)
		// Rewrites over a 1 MiB window, as a database log does.
		if _, err := f.WriteAt(buf, int64(i%256)*4096); err != nil {
			fmt.Println("write:", err)
			os.Exit(1)
		}
		if sync {
			if err := syscall.Fdatasync(int(f.Fd())); err != nil {
				fmt.Println("fdatasync:", err)
				os.Exit(1)
			}
		}
	}
	el := time.Since(start)
	fmt.Printf("%s %d x 4 KiB %s: %.1f us each\n", os.Args[1], n, os.Args[3], float64(el.Microseconds())/float64(n))
}

// counter DEV ACK: forever, write i at offset 0 of DEV and fdatasync it, then
// write i to ACK (on the virtiofs share) and fdatasync that. Whatever ACK says
// on the Mac was synced to DEV before it.
func counter(dev, ack string) {
	d, err := os.OpenFile(dev, os.O_RDWR, 0)
	if err != nil {
		fmt.Println("open dev:", err)
		os.Exit(1)
	}
	a, err := os.OpenFile(ack, os.O_RDWR|os.O_CREATE, 0o644)
	if err != nil {
		fmt.Println("open ack:", err)
		os.Exit(1)
	}
	buf := make([]byte, 4096)
	for i := uint64(1); ; i++ {
		s := fmt.Sprintf("%020d\n", i)
		copy(buf, s)
		if _, err := d.WriteAt(buf, 0); err != nil {
			fmt.Println("write dev:", err)
			os.Exit(1)
		}
		if err := syscall.Fdatasync(int(d.Fd())); err != nil {
			fmt.Println("sync dev:", err)
			os.Exit(1)
		}
		if _, err := a.WriteAt([]byte(s), 0); err != nil {
			fmt.Println("write ack:", err)
			os.Exit(1)
		}
		if err := syscall.Fdatasync(int(a.Fd())); err != nil {
			fmt.Println("sync ack:", err)
			os.Exit(1)
		}
	}
}
