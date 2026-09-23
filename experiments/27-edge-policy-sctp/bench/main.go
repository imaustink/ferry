// bench measures what ferry-proxy costs a connection: sequential new
// connections for latency, and one large download for throughput.
//
//	go run . <host:port> [connections]
//
// The server is expected to answer GET / with something small and GET /big
// with something large (edge-bench.yaml).
package main

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"os"
	"sort"
	"strconv"
	"time"
)

func get(addr, path string) (int64, error) {
	c, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		return 0, err
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(60 * time.Second))
	fmt.Fprintf(c, "GET %s HTTP/1.0\r\nHost: bench\r\n\r\n", path)
	return io.Copy(io.Discard, bufio.NewReaderSize(c, 1<<20))
}

func main() {
	addr := os.Args[1]
	n := 1000
	if len(os.Args) > 2 {
		n, _ = strconv.Atoi(os.Args[2])
	}
	var lat []time.Duration
	failed := 0
	for i := 0; i < n; i++ {
		t := time.Now()
		if got, err := get(addr, "/"); err != nil || got == 0 {
			failed++
			continue
		}
		lat = append(lat, time.Since(t))
	}
	sort.Slice(lat, func(i, j int) bool { return lat[i] < lat[j] })
	pct := func(p float64) time.Duration {
		if len(lat) == 0 {
			return 0
		}
		return lat[int(p*float64(len(lat)-1))]
	}
	fmt.Printf("%s  connections %d failed %d  p50 %v  p90 %v  p99 %v\n",
		addr, n, failed, pct(0.5).Round(time.Microsecond), pct(0.9).Round(time.Microsecond),
		pct(0.99).Round(time.Microsecond))

	best := 0.0
	for i := 0; i < 3; i++ {
		t := time.Now()
		got, err := get(addr, "/big")
		if err != nil {
			fmt.Println("download:", err)
			return
		}
		if mb := float64(got) / 1e6 / time.Since(t).Seconds(); mb > best {
			best = mb
		}
	}
	fmt.Printf("%s  download best of 3: %.0f MB/s\n", addr, best)
}
