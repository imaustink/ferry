// fakecri is a no-op CRI runtime used to map exactly how much of the darwin
// kubelet works once a CRI endpoint is present. It creates nothing: every
// sandbox and container is an in-memory record. Its real output is the call
// log -- which CRI methods the kubelet drives, in what order, and which ones
// it expects that we have not implemented.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"sort"
	"sync"
	"syscall"
	"time"

	"google.golang.org/grpc"
	runtimeapi "k8s.io/cri-api/pkg/apis/runtime/v1"
)

var (
	endpoint  = flag.String("endpoint", "/tmp/ferry-fakecri.sock", "unix socket to listen on")
	verbosity = flag.Int("log-repeats", 2, "log only the first N calls of each method; 0 logs all")
)

// calls records how often the kubelet invoked each CRI method and whether it
// ever returned an error, so the summary can separate "polled constantly" from
// "called once and blew up".
type calls struct {
	mu     sync.Mutex
	count  map[string]int
	errs   map[string]string
	order  []string
	seq    int
	start  time.Time
}

func newCalls() *calls {
	return &calls{count: map[string]int{}, errs: map[string]string{}, start: time.Now()}
}

func (c *calls) record(method string, err error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, seen := c.count[method]; !seen {
		c.order = append(c.order, method)
	}
	c.count[method]++
	c.seq++
	if err != nil {
		c.errs[method] = err.Error()
	}
	if *verbosity == 0 || c.count[method] <= *verbosity {
		since := time.Since(c.start).Truncate(time.Millisecond)
		status := "ok"
		if err != nil {
			status = "ERR " + err.Error()
		}
		log.Printf("[%4d] %8s  %-34s %s", c.seq, since, method, status)
	} else if c.count[method] == *verbosity+1 {
		log.Printf("       ...      %-34s (further calls suppressed)", method)
	}
}

func (c *calls) summary() {
	c.mu.Lock()
	defer c.mu.Unlock()
	fmt.Fprintf(os.Stderr, "\n===== CRI CALL SUMMARY (%d total) =====\n", c.seq)
	sort.Strings(c.order)
	for _, m := range c.order {
		note := ""
		if e, bad := c.errs[m]; bad {
			note = "   <-- returned error: " + e
		}
		fmt.Fprintf(os.Stderr, "%6d  %-38s%s\n", c.count[m], m, note)
	}
	fmt.Fprintln(os.Stderr, "======================================")
}

func (c *calls) interceptor(ctx context.Context, req any, info *grpc.UnaryServerInfo, h grpc.UnaryHandler) (any, error) {
	resp, err := h(ctx, req)
	c.record(shortName(info.FullMethod), err)
	return resp, err
}

func shortName(full string) string {
	for i := len(full) - 1; i >= 0; i-- {
		if full[i] == '/' {
			return full[i+1:]
		}
	}
	return full
}

type sandbox struct {
	id     string
	meta   *runtimeapi.PodSandboxMetadata
	labels map[string]string
	anns   map[string]string
	ip     string
	made   int64
}

type container struct {
	id        string
	sandboxID string
	meta      *runtimeapi.ContainerMetadata
	image     string
	labels    map[string]string
	anns      map[string]string
	made      int64
	started   int64
	running   bool
	logPath   string
}

type runtimeSvc struct {
	runtimeapi.UnimplementedRuntimeServiceServer
	mu         sync.Mutex
	sandboxes  map[string]*sandbox
	containers map[string]*container
	n          int
	ipSeq      int
}

func (r *runtimeSvc) nextID(prefix string) string {
	r.n++
	return fmt.Sprintf("%s-%06d", prefix, r.n)
}

func (r *runtimeSvc) Version(_ context.Context, _ *runtimeapi.VersionRequest) (*runtimeapi.VersionResponse, error) {
	return &runtimeapi.VersionResponse{
		Version:           "0.1.0",
		RuntimeName:       "ferry-fakecri",
		RuntimeVersion:    "0.1.0",
		RuntimeApiVersion: "v1",
	}, nil
}

func (r *runtimeSvc) Status(_ context.Context, req *runtimeapi.StatusRequest) (*runtimeapi.StatusResponse, error) {
	resp := &runtimeapi.StatusResponse{
		Status: &runtimeapi.RuntimeStatus{Conditions: []*runtimeapi.RuntimeCondition{
			{Type: runtimeapi.RuntimeReady, Status: true},
			{Type: runtimeapi.NetworkReady, Status: true},
		}},
	}
	if req.Verbose {
		resp.Info = map[string]string{"note": "fake runtime; nothing is actually created"}
	}
	return resp, nil
}

func (r *runtimeSvc) RunPodSandbox(_ context.Context, req *runtimeapi.RunPodSandboxRequest) (*runtimeapi.RunPodSandboxResponse, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.ipSeq++
	id := r.nextID("sandbox")
	s := &sandbox{id: id, made: time.Now().UnixNano(), ip: fmt.Sprintf("10.244.0.%d", r.ipSeq+1)}
	if c := req.Config; c != nil {
		s.meta, s.labels, s.anns = c.Metadata, c.Labels, c.Annotations
	}
	r.sandboxes[id] = s
	if s.meta != nil {
		log.Printf("        -> sandbox %s for pod %s/%s  ip=%s", id, s.meta.Namespace, s.meta.Name, s.ip)
	}
	return &runtimeapi.RunPodSandboxResponse{PodSandboxId: id}, nil
}

func (r *runtimeSvc) podSandboxStatus(s *sandbox) *runtimeapi.PodSandboxStatus {
	return &runtimeapi.PodSandboxStatus{
		Id:        s.id,
		Metadata:  s.meta,
		State:     runtimeapi.PodSandboxState_SANDBOX_READY,
		CreatedAt: s.made,
		Network:   &runtimeapi.PodSandboxNetworkStatus{Ip: s.ip},
		Linux:     &runtimeapi.LinuxPodSandboxStatus{Namespaces: &runtimeapi.Namespace{Options: &runtimeapi.NamespaceOption{}}},
		Labels:    s.labels,
		Annotations: s.anns,
	}
}

func (r *runtimeSvc) PodSandboxStatus(_ context.Context, req *runtimeapi.PodSandboxStatusRequest) (*runtimeapi.PodSandboxStatusResponse, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	s, ok := r.sandboxes[req.PodSandboxId]
	if !ok {
		return nil, fmt.Errorf("sandbox %q not found", req.PodSandboxId)
	}
	return &runtimeapi.PodSandboxStatusResponse{Status: r.podSandboxStatus(s)}, nil
}

// ListPodSandbox honours the request filter. Ignoring it is not a harmless
// simplification: the kubelet uses these listings to decide which containers
// belong to which pod, and an unfiltered answer makes every pod believe it owns
// every container.
func (r *runtimeSvc) ListPodSandbox(_ context.Context, req *runtimeapi.ListPodSandboxRequest) (*runtimeapi.ListPodSandboxResponse, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	f := req.GetFilter()
	var items []*runtimeapi.PodSandbox
	for _, s := range r.sandboxes {
		if f != nil {
			if f.Id != "" && f.Id != s.id {
				continue
			}
			if st := f.GetState(); st != nil && st.State != runtimeapi.PodSandboxState_SANDBOX_READY {
				continue
			}
			if !matchLabels(f.LabelSelector, s.labels) {
				continue
			}
		}
		items = append(items, &runtimeapi.PodSandbox{
			Id: s.id, Metadata: s.meta, State: runtimeapi.PodSandboxState_SANDBOX_READY,
			CreatedAt: s.made, Labels: s.labels, Annotations: s.anns,
		})
	}
	return &runtimeapi.ListPodSandboxResponse{Items: items}, nil
}

func (r *runtimeSvc) StopPodSandbox(_ context.Context, req *runtimeapi.StopPodSandboxRequest) (*runtimeapi.StopPodSandboxResponse, error) {
	return &runtimeapi.StopPodSandboxResponse{}, nil
}

func (r *runtimeSvc) RemovePodSandbox(_ context.Context, req *runtimeapi.RemovePodSandboxRequest) (*runtimeapi.RemovePodSandboxResponse, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.sandboxes, req.PodSandboxId)
	return &runtimeapi.RemovePodSandboxResponse{}, nil
}

func (r *runtimeSvc) CreateContainer(_ context.Context, req *runtimeapi.CreateContainerRequest) (*runtimeapi.CreateContainerResponse, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	id := r.nextID("ctr")
	c := &container{id: id, sandboxID: req.PodSandboxId, made: time.Now().UnixNano()}
	if cfg := req.Config; cfg != nil {
		c.meta, c.labels, c.anns, c.logPath = cfg.Metadata, cfg.Labels, cfg.Annotations, cfg.LogPath
		if cfg.Image != nil {
			c.image = cfg.Image.Image
		}
	}
	r.containers[id] = c
	name := ""
	if c.meta != nil {
		name = c.meta.Name
	}
	log.Printf("        -> container %s (%s, image=%s) in %s", id, name, c.image, req.PodSandboxId)
	return &runtimeapi.CreateContainerResponse{ContainerId: id}, nil
}

func (r *runtimeSvc) StartContainer(_ context.Context, req *runtimeapi.StartContainerRequest) (*runtimeapi.StartContainerResponse, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	c, ok := r.containers[req.ContainerId]
	if !ok {
		return nil, fmt.Errorf("container %q not found", req.ContainerId)
	}
	c.running, c.started = true, time.Now().UnixNano()
	return &runtimeapi.StartContainerResponse{}, nil
}

func (r *runtimeSvc) ContainerStatus(_ context.Context, req *runtimeapi.ContainerStatusRequest) (*runtimeapi.ContainerStatusResponse, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	c, ok := r.containers[req.ContainerId]
	if !ok {
		return nil, fmt.Errorf("container %q not found", req.ContainerId)
	}
	state := runtimeapi.ContainerState_CONTAINER_CREATED
	if c.running {
		state = runtimeapi.ContainerState_CONTAINER_RUNNING
	}
	return &runtimeapi.ContainerStatusResponse{Status: &runtimeapi.ContainerStatus{
		Id: c.id, Metadata: c.meta, State: state, CreatedAt: c.made, StartedAt: c.started,
		Image: &runtimeapi.ImageSpec{Image: c.image}, ImageRef: c.image, ImageId: c.image,
		Labels: c.labels, Annotations: c.anns, LogPath: c.logPath,
	}}, nil
}

func (r *runtimeSvc) ListContainers(_ context.Context, req *runtimeapi.ListContainersRequest) (*runtimeapi.ListContainersResponse, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	f := req.GetFilter()
	var out []*runtimeapi.Container
	for _, c := range r.containers {
		state := runtimeapi.ContainerState_CONTAINER_CREATED
		if c.running {
			state = runtimeapi.ContainerState_CONTAINER_RUNNING
		}
		if f != nil {
			if f.Id != "" && f.Id != c.id {
				continue
			}
			if f.PodSandboxId != "" && f.PodSandboxId != c.sandboxID {
				continue
			}
			if st := f.GetState(); st != nil && st.State != state {
				continue
			}
			if !matchLabels(f.LabelSelector, c.labels) {
				continue
			}
		}
		out = append(out, &runtimeapi.Container{
			Id: c.id, PodSandboxId: c.sandboxID, Metadata: c.meta,
			Image: &runtimeapi.ImageSpec{Image: c.image}, ImageRef: c.image,
			State: state, CreatedAt: c.made, Labels: c.labels, Annotations: c.anns,
		})
	}
	return &runtimeapi.ListContainersResponse{Containers: out}, nil
}

func (r *runtimeSvc) StopContainer(_ context.Context, req *runtimeapi.StopContainerRequest) (*runtimeapi.StopContainerResponse, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if c, ok := r.containers[req.ContainerId]; ok {
		c.running = false
	}
	return &runtimeapi.StopContainerResponse{}, nil
}

func (r *runtimeSvc) RemoveContainer(_ context.Context, req *runtimeapi.RemoveContainerRequest) (*runtimeapi.RemoveContainerResponse, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.containers, req.ContainerId)
	return &runtimeapi.RemoveContainerResponse{}, nil
}

func (r *runtimeSvc) UpdateRuntimeConfig(_ context.Context, _ *runtimeapi.UpdateRuntimeConfigRequest) (*runtimeapi.UpdateRuntimeConfigResponse, error) {
	return &runtimeapi.UpdateRuntimeConfigResponse{}, nil
}

// RuntimeConfig advertises the runtime's cgroup driver. There is no cgroup
// hierarchy on the host here, so report no opinion and let the kubelet fall
// back to its own configuration.
func (r *runtimeSvc) RuntimeConfig(_ context.Context, _ *runtimeapi.RuntimeConfigRequest) (*runtimeapi.RuntimeConfigResponse, error) {
	return &runtimeapi.RuntimeConfigResponse{}, nil
}

func (r *runtimeSvc) ReopenContainerLog(_ context.Context, _ *runtimeapi.ReopenContainerLogRequest) (*runtimeapi.ReopenContainerLogResponse, error) {
	return &runtimeapi.ReopenContainerLogResponse{}, nil
}

// Stats: report nothing. If the kubelet cannot tolerate empty stats we want to
// see that failure rather than hide it behind invented numbers.
func (r *runtimeSvc) ContainerStats(_ context.Context, req *runtimeapi.ContainerStatsRequest) (*runtimeapi.ContainerStatsResponse, error) {
	return &runtimeapi.ContainerStatsResponse{}, nil
}
func (r *runtimeSvc) ListContainerStats(_ context.Context, _ *runtimeapi.ListContainerStatsRequest) (*runtimeapi.ListContainerStatsResponse, error) {
	return &runtimeapi.ListContainerStatsResponse{}, nil
}
func (r *runtimeSvc) PodSandboxStats(_ context.Context, _ *runtimeapi.PodSandboxStatsRequest) (*runtimeapi.PodSandboxStatsResponse, error) {
	return &runtimeapi.PodSandboxStatsResponse{}, nil
}
func (r *runtimeSvc) ListPodSandboxStats(_ context.Context, _ *runtimeapi.ListPodSandboxStatsRequest) (*runtimeapi.ListPodSandboxStatsResponse, error) {
	return &runtimeapi.ListPodSandboxStatsResponse{}, nil
}
func (r *runtimeSvc) ListMetricDescriptors(_ context.Context, _ *runtimeapi.ListMetricDescriptorsRequest) (*runtimeapi.ListMetricDescriptorsResponse, error) {
	return &runtimeapi.ListMetricDescriptorsResponse{}, nil
}
func (r *runtimeSvc) ListPodSandboxMetrics(_ context.Context, _ *runtimeapi.ListPodSandboxMetricsRequest) (*runtimeapi.ListPodSandboxMetricsResponse, error) {
	return &runtimeapi.ListPodSandboxMetricsResponse{}, nil
}

// matchLabels reports whether have satisfies every key in want.
func matchLabels(want, have map[string]string) bool {
	for k, v := range want {
		if have[k] != v {
			return false
		}
	}
	return true
}

type imageSvc struct {
	runtimeapi.UnimplementedImageServiceServer
	mu     sync.Mutex
	images map[string]*runtimeapi.Image
}

func (i *imageSvc) PullImage(_ context.Context, req *runtimeapi.PullImageRequest) (*runtimeapi.PullImageResponse, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	ref := req.Image.GetImage()
	i.images[ref] = &runtimeapi.Image{
		Id: ref, RepoTags: []string{ref}, RepoDigests: []string{ref},
		Size: 1 << 20,
	}
	log.Printf("        -> pulled (pretend) %s", ref)
	return &runtimeapi.PullImageResponse{ImageRef: ref}, nil
}

func (i *imageSvc) ImageStatus(_ context.Context, req *runtimeapi.ImageStatusRequest) (*runtimeapi.ImageStatusResponse, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	// A miss returns an empty response, not an error: that is how the kubelet
	// is told the image is absent and a pull is required.
	if img, ok := i.images[req.Image.GetImage()]; ok {
		return &runtimeapi.ImageStatusResponse{Image: img}, nil
	}
	return &runtimeapi.ImageStatusResponse{}, nil
}

func (i *imageSvc) ListImages(_ context.Context, _ *runtimeapi.ListImagesRequest) (*runtimeapi.ListImagesResponse, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	var out []*runtimeapi.Image
	for _, img := range i.images {
		out = append(out, img)
	}
	return &runtimeapi.ListImagesResponse{Images: out}, nil
}

func (i *imageSvc) RemoveImage(_ context.Context, req *runtimeapi.RemoveImageRequest) (*runtimeapi.RemoveImageResponse, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	delete(i.images, req.Image.GetImage())
	return &runtimeapi.RemoveImageResponse{}, nil
}

func (i *imageSvc) ImageFsInfo(_ context.Context, _ *runtimeapi.ImageFsInfoRequest) (*runtimeapi.ImageFsInfoResponse, error) {
	fs := []*runtimeapi.FilesystemUsage{{
		Timestamp:  time.Now().UnixNano(),
		FsId:       &runtimeapi.FilesystemIdentifier{Mountpoint: "/tmp/ferry-fake-imagefs"},
		UsedBytes:  &runtimeapi.UInt64Value{Value: 1 << 20},
		InodesUsed: &runtimeapi.UInt64Value{Value: 16},
	}}
	return &runtimeapi.ImageFsInfoResponse{ImageFilesystems: fs, ContainerFilesystems: fs}, nil
}

func main() {
	flag.Parse()
	log.SetFlags(0)

	_ = os.Remove(*endpoint)
	lis, err := net.Listen("unix", *endpoint)
	if err != nil {
		log.Fatalf("listen %s: %v", *endpoint, err)
	}

	c := newCalls()
	srv := grpc.NewServer(grpc.UnaryInterceptor(c.interceptor))
	runtimeapi.RegisterRuntimeServiceServer(srv, &runtimeSvc{
		sandboxes:  map[string]*sandbox{},
		containers: map[string]*container{},
	})
	runtimeapi.RegisterImageServiceServer(srv, &imageSvc{images: map[string]*runtimeapi.Image{}})

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-stop
		c.summary()
		srv.Stop()
		_ = os.Remove(*endpoint)
		os.Exit(0)
	}()

	log.Printf("fakecri listening on unix://%s", *endpoint)
	log.Printf("  seq    elapsed  method                             result")
	if err := srv.Serve(lis); err != nil {
		log.Fatalf("serve: %v", err)
	}
}
