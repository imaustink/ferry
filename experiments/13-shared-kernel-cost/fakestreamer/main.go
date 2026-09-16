// A stand-in for ferry-streamer's /pod endpoint.
//
// ferry-cri sizes a pod's VM from the pod's spec, and it learns that spec by
// asking ferry-streamer, which asks the API server. Testing that path would
// otherwise mean standing up a whole cluster; this serves the one endpoint
// involved, so the runtime can be driven by a CRI client alone and still take
// the code path a real pod takes.
package main

import (
	"encoding/json"
	"flag"
	"log"
	"net"
	"net/http"
	"os"
)

var (
	socketPath = flag.String("socket", "/tmp/shk-streamer.sock", "unix socket to serve on")
	memoryMiB  = flag.Int64("memory-mib", 0, "memory limit to report for every pod")
	cpus       = flag.Int("cpus", 0, "cpu limit to report for every pod")
)

// The shape ferry-cri decodes. Field names match ferry-streamer's own.
type podContainers struct {
	InitContainers   []string `json:"initContainers"`
	Containers       []string `json:"containers"`
	GPUContainers    []string `json:"gpuContainers"`
	Priority         int32    `json:"priority"`
	MemoryLimitBytes int64    `json:"memoryLimitBytes"`
	CPULimit         int32    `json:"cpuLimit"`
}

func main() {
	flag.Parse()
	_ = os.Remove(*socketPath)
	listener, err := net.Listen("unix", *socketPath)
	if err != nil {
		log.Fatalf("listen %s: %v", *socketPath, err)
	}
	defer listener.Close()

	mux := http.NewServeMux()
	mux.HandleFunc("/pod", func(w http.ResponseWriter, r *http.Request) {
		name := r.URL.Query().Get("name")
		// The container the harness creates carries the pod's name, so
		// reporting it here makes the expected-container set complete and the
		// VM boots on the first start rather than waiting for a sidecar that
		// is never coming.
		out := podContainers{
			Containers:       []string{name},
			MemoryLimitBytes: *memoryMiB * 1024 * 1024,
			CPULimit:         int32(*cpus),
		}
		log.Printf("/pod %s -> %d MiB, %d cpu", name, *memoryMiB, *cpus)
		json.NewEncoder(w).Encode(out)
	})

	log.Printf("serving /pod on %s (%d MiB, %d cpu)", *socketPath, *memoryMiB, *cpus)
	log.Fatal(http.Serve(listener, mux))
}
