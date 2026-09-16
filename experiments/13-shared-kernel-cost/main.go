// shkcost measures what ferry's VM-per-pod boundary costs, by driving a real
// CRI runtime into the two shapes the design question is actually about:
//
//	--shape vm-per-pod   N sandboxes, one container each   (ferry today)
//	--shape shared-vm    1 sandbox, N containers           (one kernel, N workloads)
//
// Both shapes run the same image and the same command, so the difference
// between them is the per-VM overhead: a Linux kernel, a vminitd, a guest page
// cache and the hypervisor's own bookkeeping, N times over versus once.
//
// It is deliberately a CRI client rather than a kubectl script: no kubelet, no
// scheduler, nothing reconciling behind the measurement, and the runtime under
// test is ferry's own.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	runtimeapi "k8s.io/cri-api/pkg/apis/runtime/v1"
)

var (
	endpoint = flag.String("endpoint", "/tmp/shk-cri.sock", "CRI unix socket")
	image    = flag.String("image", "ghcr.io/linuxcontainers/alpine:3.20", "image to run")
	count    = flag.Int("count", 8, "number of containers, in either shape")
	shape    = flag.String("shape", "vm-per-pod", "vm-per-pod | shared-vm")
	workload = flag.String("workload", "idle", "idle | touch | reread")
	hold     = flag.Duration("hold", 30*time.Second, "how long to hold and sample after everything is running")
	sample   = flag.Duration("sample", 3*time.Second, "memory sampling interval during the hold")
	keep     = flag.Bool("keep", false, "leave the pods running instead of tearing them down")
	out      = flag.String("out", "", "write the result as JSON to this path")
	state    = flag.String("state", "", "the runtime's state directory; VMs holding a rootfs under it are this run's")
	limitMiB = flag.Int("limit-mib", 0, "memory limit to request per container, as a pod spec would")
	allocMiB = flag.Int("alloc-mib", 0, "for -workload alloc: how much the container tries to allocate")
	custom   = flag.String("cmd", "", "for -workload custom: the shell command to run in the pod")
	cmdFile  = flag.String("cmd-file", "", "for -workload custom: read the shell command from this file")
	logGrep  = flag.String("log-grep", "", "also report container log lines containing this")
	dns      = flag.String("dns", "1.1.1.1,8.8.8.8", "resolvers to give the pod")
	privileged = flag.Bool("privileged", false, "run the container privileged (for running a container runtime inside it)")
	mount      = flag.String("mount", "", "host:guest directory to share into the pod")
)

// The workloads. `idle` is the floor: a container that touches nothing beyond
// what it takes to exist. `touch` reads the whole root filesystem, which is the
// ceiling for image-driven page cache — every page of the image resident in
// the guest that read it. `reread` reads a file twice and reports the second
// read's throughput, which is the cache question stated as time rather than
// bytes: warm in the guest that read it, cold in every other guest.
func command(kind string) []string {
	switch kind {
	case "idle":
		return []string{"/bin/sh", "-c", "sleep 100000"}
	case "touch":
		return []string{"/bin/sh", "-c",
			"find / -xdev -type f -exec cat {} + >/dev/null 2>&1; echo TOUCHED; sleep 100000"}
	case "reread":
		// 128 MiB written once and read twice. dd reports its own throughput,
		// which busybox has and `date +%N` does not. The second read is the one
		// that says whether anything is cached — and, across containers, whose
		// memory the cache is coming out of.
		return []string{"/bin/sh", "-c",
			"dd if=/dev/zero of=/blob bs=1M count=128 2>/dev/null; sync; " +
				"dd if=/blob of=/dev/null bs=1M 2>&1 | tail -1 | sed 's/^/COLD /'; " +
				"dd if=/blob of=/dev/null bs=1M 2>&1 | tail -1 | sed 's/^/WARM /'; " +
				"sleep 100000"}
	case "custom":
		// An escape hatch for one-off measurements that want a specific
		// command in a pod VM rather than one of the shapes above. Scripts long
		// enough to be interesting come from a file rather than a flag.
		script := *custom
		if *cmdFile != "" {
			body, err := os.ReadFile(*cmdFile)
			if err != nil {
				log.Fatalf("read %s: %v", *cmdFile, err)
			}
			script = string(body)
		}
		return []string{"/bin/sh", "-c", script}
	case "alloc":
		// Asks for memory the pod spec says it is allowed to have. Needs an
		// image with a real allocator, so run this one on python.
		return []string{"python3", "-c", fmt.Sprintf(
			"b=bytearray(%d*1024*1024)\n"+
				"for i in range(0,len(b),4096): b[i]=1\n"+
				"print('ALLOCATED %d MiB',flush=True)\n"+
				"import time; time.sleep(100000)", *allocMiB, *allocMiB)}
	default:
		log.Fatalf("unknown workload %q", kind)
		return nil
	}
}

// memory is one sample of what the machine is holding. Two views, because
// neither alone is trustworthy: vm_stat is host-wide truth but includes
// everything else running on the Mac, while the per-VM resident sizes are
// attributable to this run but are the hypervisor's accounting rather than
// the kernel's.
type memory struct {
	At           string  `json:"at"`
	FreeMiB      float64 `json:"free_mib"`
	UsedMiB      float64 `json:"used_mib"` // active + wired + compressed
	CompressedMiB float64 `json:"compressed_mib"`
	VMs          int     `json:"vms"`      // VM processes started by this run
	VMResidentMiB float64 `json:"vm_resident_mib"`
	VMCPUPercent  float64 `json:"vm_cpu_percent"`
}

type result struct {
	Shape         string   `json:"shape"`
	Workload      string   `json:"workload"`
	Image         string   `json:"image"`
	Count         int      `json:"count"`
	CreateSeconds float64  `json:"create_seconds"` // to all containers running
	Baseline      memory   `json:"baseline"`
	Samples       []memory `json:"samples"`
	Peak          memory   `json:"peak"`
	FootprintMiB  float64  `json:"footprint_mib"` // phys_footprint, measured once at the end
	Logs          []string `json:"logs"`          // markers the workloads printed
}

// footprint sums the physical footprint of this run's VM processes. It is the
// number macOS itself charges a process — resident minus the shared library
// pages every VM process maps a copy of — so it is the honest per-pod cost,
// but vmmap takes the better part of a second per process, which is why it is
// taken once at the end rather than sampled.
func footprint(before map[int]float64) float64 {
	total := 0.0
	for pid := range vmProcesses() {
		if _, existed := before[pid]; existed {
			continue
		}
		body, err := exec.Command("vmmap", "--summary", strconv.Itoa(pid)).Output()
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(body), "\n") {
			if !strings.HasPrefix(line, "Physical footprint:") {
				continue
			}
			value := strings.TrimSpace(strings.TrimPrefix(line, "Physical footprint:"))
			scale := 1.0
			switch {
			case strings.HasSuffix(value, "G"):
				scale, value = 1024, strings.TrimSuffix(value, "G")
			case strings.HasSuffix(value, "M"):
				scale, value = 1, strings.TrimSuffix(value, "M")
			case strings.HasSuffix(value, "K"):
				scale, value = 1.0/1024, strings.TrimSuffix(value, "K")
			}
			if n, err := strconv.ParseFloat(value, 64); err == nil {
				total += n * scale
			}
			break
		}
	}
	return total
}

const pageMiB = 16384.0 / (1024 * 1024) // macOS on arm64 pages are 16 KiB

func vmStat() (free, used, compressed float64) {
	outBytes, err := exec.Command("vm_stat").Output()
	if err != nil {
		log.Fatalf("vm_stat: %v", err)
	}
	pages := map[string]float64{}
	scanner := bufio.NewScanner(strings.NewReader(string(outBytes)))
	for scanner.Scan() {
		line := scanner.Text()
		colon := strings.Index(line, ":")
		if colon < 0 {
			continue
		}
		key := strings.TrimSpace(line[:colon])
		value := strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(line[colon+1:]), "."))
		n, err := strconv.ParseFloat(value, 64)
		if err != nil {
			continue
		}
		pages[key] = n
	}
	free = (pages["Pages free"] + pages["Pages speculative"]) * pageMiB
	compressed = pages["Pages occupied by compressor"] * pageMiB
	used = (pages["Pages active"] + pages["Pages wired down"]) * pageMiB + compressed
	return free, used, compressed
}

// vmProcesses returns the pid -> resident MiB of every Virtualization.framework
// VM process on the machine.
//
// A VM process is a child of launchd, not of the runtime that asked for it, so
// there is no parentage to filter on. Diffing the process set before and after
// is not enough either: a cluster running on the same Mac starts and stops pods
// while the measurement is in flight, and one of those lands in the diff as if
// it were ours. Ownership is settled by what the process has open — every VM
// holds the rootfs of its containers, and ours are the only ones under this
// experiment's state directory.
func vmProcesses() map[int]float64 {
	outBytes, err := exec.Command("ps", "-Ao", "pid=,rss=,comm=").Output()
	if err != nil {
		log.Fatalf("ps: %v", err)
	}
	found := map[int]float64{}
	scanner := bufio.NewScanner(strings.NewReader(string(outBytes)))
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 3 || !strings.Contains(fields[2], "Virtualization.VirtualMachine") {
			continue
		}
		pid, err := strconv.Atoi(fields[0])
		if err != nil {
			continue
		}
		rss, err := strconv.ParseFloat(fields[1], 64)
		if err != nil {
			continue
		}
		if *state != "" && !holdsRootfsUnder(pid, *state) {
			continue
		}
		found[pid] = rss / 1024
	}
	return found
}

// holdsRootfsUnder reports whether a VM process has a file open under dir,
// which for a ferry pod means a container rootfs it was given.
func holdsRootfsUnder(pid int, dir string) bool {
	body, err := exec.Command("lsof", "-p", strconv.Itoa(pid), "-Fn").Output()
	if err != nil {
		// lsof exits non-zero when some descriptors cannot be read; whatever it
		// did print is still worth matching against.
		if len(body) == 0 {
			return false
		}
	}
	return strings.Contains(string(body), dir)
}

// cpuPercent is the CPU the VM processes are burning between them: N kernels
// each running their own timers and housekeeping, against one.
func cpuPercent(pids map[int]float64) float64 {
	if len(pids) == 0 {
		return 0
	}
	args := []string{"-o", "%cpu="}
	for pid := range pids {
		args = append(args, "-p", strconv.Itoa(pid))
	}
	body, err := exec.Command("ps", args...).Output()
	if err != nil {
		return 0
	}
	total := 0.0
	for _, line := range strings.Fields(string(body)) {
		if n, err := strconv.ParseFloat(line, 64); err == nil {
			total += n
		}
	}
	return total
}

func measure(before map[int]float64) memory {
	free, used, compressed := vmStat()
	mine := map[int]float64{}
	resident := 0.0
	for pid, rss := range vmProcesses() {
		if _, existed := before[pid]; existed {
			continue
		}
		mine[pid] = rss
		resident += rss
	}
	return memory{
		At: time.Now().Format("15:04:05"), FreeMiB: free, UsedMiB: used,
		CompressedMiB: compressed, VMs: len(mine), VMResidentMiB: resident,
		VMCPUPercent: cpuPercent(mine),
	}
}

func main() {
	flag.Parse()
	ctx := context.Background()

	conn, err := grpc.NewClient("unix://"+*endpoint,
		grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		log.Fatalf("dial %s: %v", *endpoint, err)
	}
	defer conn.Close()
	rt := runtimeapi.NewRuntimeServiceClient(conn)
	img := runtimeapi.NewImageServiceClient(conn)

	// Pull first and outside the timing: this measures running containers, not
	// fetching them, and the unpacked rootfs is cached by the runtime anyway.
	//
	// Ask the runtime whether it already has the image before reaching for the
	// registry. A battery that runs twenty cells against the same image would
	// otherwise pull it twenty times, and Docker Hub answers the tenth or so
	// with 429 — which looks like a benchmark failure and is not one.
	have := false
	if status, err := img.ImageStatus(ctx, &runtimeapi.ImageStatusRequest{
		Image: &runtimeapi.ImageSpec{Image: *image},
	}); err == nil && status.Image != nil {
		have = true
	}
	if have {
		log.Printf("using cached %s", *image)
	} else {
		log.Printf("pulling %s", *image)
		if _, err := img.PullImage(ctx, &runtimeapi.PullImageRequest{
			Image: &runtimeapi.ImageSpec{Image: *image},
		}); err != nil {
			log.Fatalf("pull: %v", err)
		}
	}

	logDir, err := os.MkdirTemp("", "shk-logs")
	if err != nil {
		log.Fatalf("log dir: %v", err)
	}

	// Let the machine settle before the baseline, so the pull's own page cache
	// is not charged to the pods.
	time.Sleep(3 * time.Second)
	preexisting := vmProcesses()
	baseline := measure(preexisting)
	log.Printf("baseline: %.0f MiB free, %.0f MiB used", baseline.FreeMiB, baseline.UsedMiB)

	cmd := command(*workload)
	started := time.Now()
	var sandboxIDs []string
	var containerIDs []string

	newSandbox := func(name string) string {
		cfg := &runtimeapi.PodSandboxConfig{
			Metadata: &runtimeapi.PodSandboxMetadata{
				Name: name, Uid: name, Namespace: "shkcost", Attempt: 0,
			},
			Hostname:     name,
			LogDirectory: logDir,
			Linux:        &runtimeapi.LinuxPodSandboxConfig{},
			// There is no CoreDNS here — this runtime serves no cluster — so a
			// pod that needs to resolve anything needs to be told where to ask.
			DnsConfig: &runtimeapi.DNSConfig{Servers: strings.Split(*dns, ",")},
		}
		resp, err := rt.RunPodSandbox(ctx, &runtimeapi.RunPodSandboxRequest{Config: cfg})
		if err != nil {
			log.Fatalf("RunPodSandbox %s: %v", name, err)
		}
		sandboxIDs = append(sandboxIDs, resp.PodSandboxId)
		return resp.PodSandboxId
	}
	newContainer := func(sandbox, name string) string {
		cfg := &runtimeapi.PodSandboxConfig{
			Metadata:     &runtimeapi.PodSandboxMetadata{Name: name, Uid: name, Namespace: "shkcost"},
			LogDirectory: logDir,
		}
		container := &runtimeapi.ContainerConfig{
			Metadata: &runtimeapi.ContainerMetadata{Name: name},
			Image:    &runtimeapi.ImageSpec{Image: *image},
			Command:  cmd,
			LogPath:  name + ".log",
		}
		// host:guest, so a benchmark can carry its tools in rather than fetch
		// them — deterministic versions, and no network in the measured path.
		if *mount != "" {
			parts := strings.SplitN(*mount, ":", 2)
			if len(parts) != 2 {
				log.Fatalf("-mount wants host:guest, got %q", *mount)
			}
			container.Mounts = []*runtimeapi.Mount{{
				HostPath:      parts[0],
				ContainerPath: parts[1],
				Readonly:      false,
			}}
		}
		if *limitMiB > 0 || *privileged {
			container.Linux = &runtimeapi.LinuxContainerConfig{}
			if *limitMiB > 0 {
				// Exactly what the kubelet sends for `limits.memory`.
				container.Linux.Resources = &runtimeapi.LinuxContainerResources{
					MemoryLimitInBytes: int64(*limitMiB) * 1024 * 1024,
				}
			}
			if *privileged {
				// A container runtime inside the guest needs to mount, to write
				// cgroups, and to set up its own namespaces.
				container.Linux.SecurityContext = &runtimeapi.LinuxContainerSecurityContext{
					Privileged: true,
				}
			}
		}
		resp, err := rt.CreateContainer(ctx, &runtimeapi.CreateContainerRequest{
			PodSandboxId:  sandbox,
			Config:        container,
			SandboxConfig: cfg,
		})
		if err != nil {
			log.Fatalf("CreateContainer %s: %v", name, err)
		}
		containerIDs = append(containerIDs, resp.ContainerId)
		return resp.ContainerId
	}

	switch *shape {
	case "vm-per-pod":
		// One sandbox per container: N VMs. Created serially, which is what the
		// kubelet does, so the elapsed time is comparable to a real pod burst.
		for i := 0; i < *count; i++ {
			name := fmt.Sprintf("pod-%02d", i)
			sandbox := newSandbox(name)
			id := newContainer(sandbox, name)
			if _, err := rt.StartContainer(ctx, &runtimeapi.StartContainerRequest{ContainerId: id}); err != nil {
				log.Fatalf("StartContainer %s: %v", name, err)
			}
		}
	case "shared-vm":
		// One sandbox holding every container: one VM, one kernel. Every
		// container has to exist before the first start, because the hypervisor
		// cannot add one to a running VM — the same constraint that makes
		// sidecars work the way they do.
		sandbox := newSandbox("shared")
		for i := 0; i < *count; i++ {
			newContainer(sandbox, fmt.Sprintf("ctr-%02d", i))
		}
		for _, id := range containerIDs {
			if _, err := rt.StartContainer(ctx, &runtimeapi.StartContainerRequest{ContainerId: id}); err != nil {
				log.Fatalf("StartContainer %s: %v", id, err)
			}
		}
	default:
		log.Fatalf("unknown shape %q", *shape)
	}

	// Everything is started; wait until the runtime agrees everything is
	// running before stopping the clock.
	deadline := time.Now().Add(2 * time.Minute)
	for {
		running := 0
		for _, id := range containerIDs {
			status, err := rt.ContainerStatus(ctx, &runtimeapi.ContainerStatusRequest{ContainerId: id})
			if err == nil && status.Status.State == runtimeapi.ContainerState_CONTAINER_RUNNING {
				running++
			}
		}
		if running == len(containerIDs) {
			break
		}
		if time.Now().After(deadline) {
			log.Fatalf("only %d/%d containers running after 2m", running, len(containerIDs))
		}
		time.Sleep(200 * time.Millisecond)
	}
	elapsed := time.Since(started)
	log.Printf("%d containers running in %s", len(containerIDs), elapsed.Round(time.Millisecond))

	res := result{
		Shape: *shape, Workload: *workload, Image: *image, Count: *count,
		CreateSeconds: elapsed.Seconds(), Baseline: baseline,
	}

	// Hold and sample. The series matters as much as the endpoint: a workload
	// that is still pulling pages in has not finished costing what it costs.
	for end := time.Now().Add(*hold); time.Now().Before(end); {
		time.Sleep(*sample)
		s := measure(preexisting)
		res.Samples = append(res.Samples, s)
		log.Printf("  +%-4s %d VMs, %.0f MiB resident, %.1f%% cpu, host used %+.0f MiB",
			time.Since(started).Round(time.Second), s.VMs, s.VMResidentMiB, s.VMCPUPercent,
			s.UsedMiB-baseline.UsedMiB)
	}
	for _, s := range res.Samples {
		if s.VMResidentMiB > res.Peak.VMResidentMiB {
			res.Peak = s
		}
	}
	res.FootprintMiB = footprint(preexisting)

	// Whatever markers the workloads printed — TOUCHED, REREAD_NS — so a run
	// can say whether the workload actually finished before it was measured.
	entries, _ := os.ReadDir(logDir)
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		names = append(names, e.Name())
	}
	sort.Strings(names)
	for _, name := range names {
		body, err := os.ReadFile(logDir + "/" + name)
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(body), "\n") {
			if strings.Contains(line, "TOUCHED") || strings.Contains(line, "COLD ") ||
				strings.Contains(line, "WARM ") || strings.Contains(line, "ALLOCATED") ||
				strings.Contains(line, "MemoryError") || strings.Contains(line, "Killed") ||
				(*logGrep != "" && strings.Contains(line, *logGrep)) {
				res.Logs = append(res.Logs, name+": "+strings.TrimSpace(line))
			}
		}
	}

	fmt.Println()
	fmt.Printf("shape           %s\n", res.Shape)
	fmt.Printf("workload        %s on %s\n", res.Workload, res.Image)
	fmt.Printf("containers      %d in %d VM(s)\n", res.Count, res.Peak.VMs)
	fmt.Printf("time to running %.2fs\n", res.CreateSeconds)
	fmt.Printf("VM resident     %.0f MiB total, %.1f MiB per container\n",
		res.Peak.VMResidentMiB, res.Peak.VMResidentMiB/float64(res.Count))
	fmt.Printf("VM footprint    %.0f MiB total, %.1f MiB per container\n",
		res.FootprintMiB, res.FootprintMiB/float64(res.Count))
	fmt.Printf("VM cpu          %.1f%% across %d VM(s), idle-ish\n",
		res.Peak.VMCPUPercent, res.Peak.VMs)
	fmt.Printf("host used delta %+.0f MiB\n", res.Peak.UsedMiB-baseline.UsedMiB)
	for _, line := range res.Logs {
		fmt.Printf("  %s\n", line)
	}

	if *out != "" {
		body, _ := json.MarshalIndent(res, "", "  ")
		if err := os.WriteFile(*out, body, 0o644); err != nil {
			log.Printf("write %s: %v", *out, err)
		}
	}

	if *keep {
		log.Printf("leaving %d sandbox(es) running", len(sandboxIDs))
		return
	}
	for _, id := range sandboxIDs {
		if _, err := rt.StopPodSandbox(ctx, &runtimeapi.StopPodSandboxRequest{PodSandboxId: id}); err != nil {
			log.Printf("stop %s: %v", id, err)
		}
		if _, err := rt.RemovePodSandbox(ctx, &runtimeapi.RemovePodSandboxRequest{PodSandboxId: id}); err != nil {
			log.Printf("remove %s: %v", id, err)
		}
	}
	log.Printf("torn down")
}
