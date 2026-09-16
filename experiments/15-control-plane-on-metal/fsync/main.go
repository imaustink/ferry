// Why etcd is slower on the metal than in a VM on the same metal.
//
// Go's os.File.Sync() on darwin issues F_FULLFSYNC, which tells the drive to
// flush its write cache and does not return until it has. Plain fsync(2) on
// macOS does not: it pushes the data to the device and returns, leaving it in
// the device's cache. A guest's fsync becomes a virtio flush, which the host
// serves according to the disk attachment's synchronization mode — and
// Containerization's default for a disk image is .fsync, the weaker one.
//
// So the two sides of the etcd comparison are not doing the same work. This
// times both calls against the same file on the same filesystem to say how much
// of the difference that accounts for.
package main

import (
	"fmt"
	"os"
	"syscall"
	"time"
)

func main() {
	path := os.TempDir() + "/ferry-fsync-probe"
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR|os.O_TRUNC, 0o644)
	if err != nil {
		panic(err)
	}
	defer os.Remove(path)
	defer file.Close()

	block := make([]byte, 4096)

	// One write plus one durability call, the shape of a WAL append.
	measure := func(name string, sync func() error) {
		const rounds = 200
		var total time.Duration
		var worst time.Duration
		for i := 0; i < rounds; i++ {
			if _, err := file.Write(block); err != nil {
				panic(err)
			}
			start := time.Now()
			if err := sync(); err != nil {
				panic(err)
			}
			took := time.Since(start)
			total += took
			if took > worst {
				worst = took
			}
		}
		fmt.Printf("%-28s mean %7.3f ms   worst %7.3f ms\n",
			name, float64(total.Microseconds())/float64(rounds)/1000,
			float64(worst.Microseconds())/1000)
	}

	// What Go — and therefore etcd — actually calls on darwin.
	measure("os.File.Sync (F_FULLFSYNC)", file.Sync)
	// What the host does on a guest's behalf under synchronizationMode .fsync.
	measure("syscall.Fsync (plain fsync)", func() error {
		return syscall.Fsync(int(file.Fd()))
	})
}
