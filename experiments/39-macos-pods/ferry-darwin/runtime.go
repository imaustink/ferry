package main

// The CRI RuntimeService, run on a macOS node.
//
// A sandbox is an address, a uid and a directory. A container is a process:
// chrooted into a root of hard links (the node's dyld and shared cache, the
// image's files, the address shim), running as the pod's uid, with
// podnet.dylib putting its wildcard binds and outbound connections on the
// pod's address. Its output is written in the CRI log format to the path the
// kubelet names, which is all `kubectl logs` needs.
//
// The listings honour their filters, as fakecri's did: the kubelet derives
// which containers belong to which pod from them.

import (
	"context"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	runtimeapi "k8s.io/cri-api/pkg/apis/runtime/v1"
	"k8s.io/kubelet/pkg/cri/streaming"
)

const handler = "ferry-darwin"

type sandbox struct {
	id     string
	meta   *runtimeapi.PodSandboxMetadata
	labels map[string]string
	anns   map[string]string
	logDir string
	addr   podAddr
	made   int64
	ready  bool
}

type container struct {
	id        string
	sandboxID string
	meta      *runtimeapi.ContainerMetadata
	image     *image
	labels    map[string]string
	anns      map[string]string
	logPath   string
	root      string
	argv      []string
	env       []string
	workdir   string
	mounts    []volumeMount
	// As the kubelet sent them: returned in ContainerStatus, which is where it
	// looks up the host path of /dev/termination-log to read a message from.
	criMounts []*runtimeapi.Mount
	// The pod's memory limit in bytes, 0 for none. macOS has no cgroup to
	// enforce it, so a watcher kills the container when it is exceeded -- a
	// poor man's OOM killer, so one pod cannot take a shared machine down.
	memLimit int64
	// The pod's CPU limit as a CFS quota and period (microseconds); the ceiling
	// in cores is quota/period, 0 for none. No cgroup here either, so a watcher
	// duty-cycles the group with SIGSTOP/SIGCONT to hold it near the limit.
	cpuQuota, cpuPeriod int64
	// stdio, for kubectl attach: what the pod asked for, and what it got.
	tty, openStdin, stdinOnce bool
	stdin                     io.WriteCloser
	pty                       *os.File
	fan                       fanout

	// Where the container lives outside its root (state.go), its output files
	// (tail.go), how far they have been read into the kubelet's log, and the
	// log itself.
	dir                    string
	stdoutPath, stderrPath string
	logOffsets             [2]int64
	clog                   *criLog
	// The container's pid, which is also its process group, and its reaper's
	// (reap.go). A terminal container has no reaper: it is the runtime's child.
	pid, reaperPid int

	mu        sync.Mutex
	state     runtimeapi.ContainerState
	made      int64
	started   int64
	finished  int64
	exit      int32
	reason    string
	message   string
	oomKilled bool
	cmd       *exec.Cmd
	done      chan struct{}
}

type runtimeSvc struct {
	runtimeapi.UnimplementedRuntimeServiceServer
	node   *node
	images *imageSvc
	mu     sync.Mutex
	sboxes map[string]*sandbox
	ctrs   map[string]*container
	n      int
	// podVMOwner is the uid of the one pod a -pod-vm machine is for.
	podVMOwner string
	// debugAnnotations honours the ferry.dev/debug-* pod annotations.
	debugAnnotations bool
	// boot is this boot's session id, which state on disk is checked against.
	boot      string
	services  *serviceTable // nil when not given an API server
	streaming streaming.Server
	// The kubelet's pods directory, exported over NFS; empty leaves volumes off.
	volumesRoots []string
	nfsReady     chan struct{} // closed once nfsd serves volumesRoots
	nfsErr       error
	// The Mac's PersistentVolume share, served per volume by pv.
	hostVolumes string
	pv          pvServers
}

// roots is every container root, for the service table to be written into.
func (r *runtimeSvc) roots() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []string
	for _, c := range r.ctrs {
		out = append(out, c.root)
	}
	return out
}

func (r *runtimeSvc) nextID(prefix string) string {
	r.n++
	return fmt.Sprintf("%s-%06d", prefix, r.n)
}

func (r *runtimeSvc) Version(_ context.Context, _ *runtimeapi.VersionRequest) (*runtimeapi.VersionResponse, error) {
	return &runtimeapi.VersionResponse{Version: "0.1.0", RuntimeName: "ferry-darwin", RuntimeVersion: "0.1.0", RuntimeApiVersion: "v1"}, nil
}

func (r *runtimeSvc) Status(_ context.Context, _ *runtimeapi.StatusRequest) (*runtimeapi.StatusResponse, error) {
	// Not network-ready until the node has its slice of the pod network, so
	// the kubelet holds pods back rather than have them fail for an address --
	// the same signal a Linux node's CNI gives before its config exists.
	network := &runtimeapi.RuntimeCondition{Type: runtimeapi.NetworkReady, Status: r.node.networkReady()}
	if !network.Status {
		network.Reason, network.Message = "NoPodCIDR", "waiting for this node's pod CIDR"
	}
	return &runtimeapi.StatusResponse{
		Status: &runtimeapi.RuntimeStatus{Conditions: []*runtimeapi.RuntimeCondition{
			{Type: runtimeapi.RuntimeReady, Status: true},
			network,
		}},
		RuntimeHandlers: []*runtimeapi.RuntimeHandler{{Name: handler, Features: &runtimeapi.RuntimeHandlerFeatures{}}},
	}, nil
}

// MARK: sandboxes

func (r *runtimeSvc) RunPodSandbox(_ context.Context, req *runtimeapi.RunPodSandboxRequest) (*runtimeapi.RunPodSandboxResponse, error) {
	// The CRI says an unknown handler is refused; a Linux pod that reached
	// this node would otherwise be unpacked and fail at exec.
	if h := req.RuntimeHandler; h != "" && h != handler {
		return nil, fmt.Errorf("this macOS node serves RuntimeClass handler %q, not %q", handler, h)
	}
	r.mu.Lock()
	// A pod's VM runs one pod, ever: the second would inherit what the first
	// did as root. ferry-machined taints the node once a pod is bound to it;
	// this is for a pod bound in the moment before that. The same pod again --
	// the kubelet recreating its sandbox -- is still its own.
	if r.node.podVM && req.Config != nil && req.Config.Metadata != nil {
		uid := req.Config.Metadata.Uid
		if r.podVMOwner != "" && r.podVMOwner != uid {
			r.mu.Unlock()
			return nil, fmt.Errorf("this macOS VM was pod %s's, and runs no other pod", r.podVMOwner)
		}
		r.podVMOwner = uid
	}
	id := r.nextID("sandbox")
	r.mu.Unlock()
	defer r.saveRuntime()
	addr, err := r.node.allocate(id)
	if err != nil {
		return nil, err
	}
	s := &sandbox{id: id, addr: addr, made: time.Now().UnixNano(), ready: true}
	if c := req.Config; c != nil {
		s.meta, s.labels, s.anns, s.logDir = c.Metadata, c.Labels, c.Annotations, c.LogDirectory
	}
	if err := os.MkdirAll(filepath.Join(r.node.state, "pods", id), 0o755); err != nil {
		return nil, err
	}
	r.mu.Lock()
	r.sboxes[id] = s
	r.mu.Unlock()
	r.saveSandbox(s)
	if s.meta != nil {
		log.Printf("sandbox %s: pod %s/%s at %s, uid %d", id, s.meta.Namespace, s.meta.Name, addr.ip, addr.uid)
	}
	return &runtimeapi.RunPodSandboxResponse{PodSandboxId: id}, nil
}

func (r *runtimeSvc) sandboxState(s *sandbox) runtimeapi.PodSandboxState {
	if s.ready {
		return runtimeapi.PodSandboxState_SANDBOX_READY
	}
	return runtimeapi.PodSandboxState_SANDBOX_NOTREADY
}

func (r *runtimeSvc) PodSandboxStatus(_ context.Context, req *runtimeapi.PodSandboxStatusRequest) (*runtimeapi.PodSandboxStatusResponse, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	s, ok := r.sboxes[req.PodSandboxId]
	if !ok {
		return nil, fmt.Errorf("sandbox %q not found", req.PodSandboxId)
	}
	return &runtimeapi.PodSandboxStatusResponse{Status: &runtimeapi.PodSandboxStatus{
		Id: s.id, Metadata: s.meta, State: r.sandboxState(s), CreatedAt: s.made,
		Network: &runtimeapi.PodSandboxNetworkStatus{Ip: s.addr.ip},
		Linux:   &runtimeapi.LinuxPodSandboxStatus{Namespaces: &runtimeapi.Namespace{Options: &runtimeapi.NamespaceOption{}}},
		Labels:  s.labels, Annotations: s.anns, RuntimeHandler: handler,
	}}, nil
}

func (r *runtimeSvc) ListPodSandbox(_ context.Context, req *runtimeapi.ListPodSandboxRequest) (*runtimeapi.ListPodSandboxResponse, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	f := req.GetFilter()
	var items []*runtimeapi.PodSandbox
	for _, s := range r.sboxes {
		st := r.sandboxState(s)
		if f != nil {
			if f.Id != "" && f.Id != s.id {
				continue
			}
			if w := f.GetState(); w != nil && w.State != st {
				continue
			}
			if !matchLabels(f.LabelSelector, s.labels) {
				continue
			}
		}
		items = append(items, &runtimeapi.PodSandbox{
			Id: s.id, Metadata: s.meta, State: st, CreatedAt: s.made,
			Labels: s.labels, Annotations: s.anns, RuntimeHandler: handler,
		})
	}
	return &runtimeapi.ListPodSandboxResponse{Items: items}, nil
}

func (r *runtimeSvc) StopPodSandbox(_ context.Context, req *runtimeapi.StopPodSandboxRequest) (*runtimeapi.StopPodSandboxResponse, error) {
	r.mu.Lock()
	s, ok := r.sboxes[req.PodSandboxId]
	var ctrs []*container
	for _, c := range r.ctrs {
		if c.sandboxID == req.PodSandboxId {
			ctrs = append(ctrs, c)
		}
	}
	r.mu.Unlock()
	for _, c := range ctrs {
		c.stop(10 * time.Second)
	}
	if ok && s.ready {
		r.node.release(s.id)
		s.ready = false
		r.saveSandbox(s)
	}
	return &runtimeapi.StopPodSandboxResponse{}, nil
}

func (r *runtimeSvc) RemovePodSandbox(ctx context.Context, req *runtimeapi.RemovePodSandboxRequest) (*runtimeapi.RemovePodSandboxResponse, error) {
	_, _ = r.StopPodSandbox(ctx, &runtimeapi.StopPodSandboxRequest{PodSandboxId: req.PodSandboxId})
	r.mu.Lock()
	var ctrs []string
	for id, c := range r.ctrs {
		if c.sandboxID == req.PodSandboxId {
			ctrs = append(ctrs, id)
		}
	}
	r.mu.Unlock()
	for _, id := range ctrs {
		_, _ = r.RemoveContainer(ctx, &runtimeapi.RemoveContainerRequest{ContainerId: id})
	}
	r.mu.Lock()
	delete(r.sboxes, req.PodSandboxId)
	r.mu.Unlock()
	_ = os.RemoveAll(filepath.Join(r.node.state, "pods", req.PodSandboxId))
	return &runtimeapi.RemovePodSandboxResponse{}, nil
}

// MARK: containers

func (r *runtimeSvc) CreateContainer(_ context.Context, req *runtimeapi.CreateContainerRequest) (*runtimeapi.CreateContainerResponse, error) {
	cfg := req.Config
	r.mu.Lock()
	s, ok := r.sboxes[req.PodSandboxId]
	id := r.nextID("ctr")
	r.mu.Unlock()
	if !ok {
		return nil, fmt.Errorf("sandbox %q not found", req.PodSandboxId)
	}
	img := r.images.lookup(cfg.GetImage().GetImage())
	if img == nil {
		return nil, fmt.Errorf("image %q is not on this node", cfg.GetImage().GetImage())
	}
	mounts, err := r.planMounts(cfg.Mounts)
	if err != nil {
		return nil, err
	}

	// The root: the node's OS files and the image's, hard links both, plus a
	// /dev and a /tmp of its own.
	root := filepath.Join(r.node.state, "pods", s.id, id)
	if err := linkTree(filepath.Join(r.node.state, "os"), root); err != nil {
		return nil, fmt.Errorf("root: os: %w", err)
	}
	if err := linkTree(img.rootfs, root); err != nil {
		return nil, fmt.Errorf("root: image: %w", err)
	}
	for _, d := range []string{"dev", "tmp"} {
		_ = os.MkdirAll(filepath.Join(root, d), 0o755)
	}
	_ = os.Chmod(filepath.Join(root, "tmp"), 0o1777)
	// On a Mac /tmp is a link to /private/tmp, and tools that resolve paths
	// (or print them) use the second; here the other way round, to the same
	// directory.
	_ = os.MkdirAll(filepath.Join(root, "private"), 0o755)
	_ = os.Symlink("../tmp", filepath.Join(root, "private", "tmp"))
	// Name resolution. libSystem's resolver asks mDNSResponder over a UNIX
	// socket at /var/run/mDNSResponder, and inside a chroot that path is
	// missing -- so a pod could reach a Service by address and not resolve its
	// name, while the node resolved the same name fine. A hard link to the
	// socket is the socket, so the pod asks the node's resolver, and cluster
	// names go to cluster DNS by /etc/resolver. If mDNSResponder restarts it
	// makes a new socket and this link goes stale; not handled.
	_ = os.MkdirAll(filepath.Join(root, "var", "run"), 0o755)
	if err := os.Link("/private/var/run/mDNSResponder", filepath.Join(root, "var", "run", "mDNSResponder")); err != nil {
		log.Printf("container %s: no name resolution: %v", id, err)
	}
	if r.services != nil {
		r.services.install(root)
	}

	// Kubernetes' command replaces the entrypoint and its args replace the
	// cmd, as for any image.
	argv := append(append([]string{}, img.entrypoint...), img.cmd...)
	if len(cfg.Command) > 0 {
		argv = append(append([]string{}, cfg.Command...), cfg.Args...)
	} else if len(cfg.Args) > 0 {
		argv = append(append([]string{}, img.entrypoint...), cfg.Args...)
	}
	if len(argv) == 0 {
		return nil, fmt.Errorf("container %s has no command and its image no entrypoint", cfg.GetMetadata().GetName())
	}
	env := append([]string{"PATH=" + defaultPath, "HOME=/tmp", "TMPDIR=/tmp"}, img.env...)
	for _, kv := range cfg.Envs {
		env = append(env, kv.Key+"="+kv.Value)
	}
	env = append(env, "DYLD_INSERT_LIBRARIES=/"+shimInRoot, "FERRY_POD_IP="+s.addr.ip)
	if cc := r.node.clusterCIDR; cc != nil {
		env = append(env, "FERRY_CLUSTER_CIDR="+cc.String())
	}
	workdir := img.workdir
	if cfg.WorkingDir != "" {
		workdir = cfg.WorkingDir
	}
	if workdir == "" {
		workdir = "/"
	}

	c := &container{
		id: id, sandboxID: s.id, meta: cfg.Metadata, image: img, labels: cfg.Labels, anns: cfg.Annotations,
		logPath: filepath.Join(s.logDir, cfg.LogPath), root: root, argv: argv, env: env, workdir: workdir,
		mounts: mounts, criMounts: cfg.Mounts,
		memLimit:  cfg.GetLinux().GetResources().GetMemoryLimitInBytes(),
		cpuQuota:  cfg.GetLinux().GetResources().GetCpuQuota(),
		cpuPeriod: cfg.GetLinux().GetResources().GetCpuPeriod(),
		tty:       cfg.Tty, openStdin: cfg.Stdin, stdinOnce: cfg.StdinOnce,
		state: runtimeapi.ContainerState_CONTAINER_CREATED, made: time.Now().UnixNano(),
		dir: r.containerDir(s.id, id),
	}
	c.stdoutPath, c.stderrPath = filepath.Join(c.dir, "stdout"), filepath.Join(c.dir, "stderr")
	if err := os.MkdirAll(c.dir, 0o755); err != nil {
		return nil, err
	}
	r.mu.Lock()
	r.ctrs[id] = c
	r.mu.Unlock()
	r.saveContainer(c)
	r.saveRuntime()
	log.Printf("container %s: %s in %s, %v", id, cfg.GetMetadata().GetName(), s.id, argv)
	return &runtimeapi.CreateContainerResponse{ContainerId: id}, nil
}

// resolve finds argv[0] inside the root the way a shell would, since the
// kernel resolves the path after chroot but exec needs a path to hand it.
func (c *container) resolve() (string, error) {
	name := c.argv[0]
	if strings.Contains(name, "/") {
		return name, nil
	}
	for _, dir := range strings.Split(defaultPath, ":") {
		if st, err := os.Stat(filepath.Join(c.root, dir, name)); err == nil && !st.IsDir() {
			return dir + "/" + name, nil
		}
	}
	return "", fmt.Errorf("%s: not found in the image", name)
}

func (r *runtimeSvc) StartContainer(_ context.Context, req *runtimeapi.StartContainerRequest) (*runtimeapi.StartContainerResponse, error) {
	r.mu.Lock()
	c, ok := r.ctrs[req.ContainerId]
	var s *sandbox
	if ok {
		s = r.sboxes[c.sandboxID]
	}
	r.mu.Unlock()
	if !ok || s == nil {
		return nil, fmt.Errorf("container %q not found", req.ContainerId)
	}
	path, err := c.resolve()
	if err != nil {
		return nil, err
	}
	if err := r.volumesUp(c.mounts); err != nil {
		return nil, err
	}
	if err := r.mountVolumes(c.root, c.mounts); err != nil {
		unmountVolumes(c.root, c.mounts)
		return nil, err
	}
	if err := makeDev(filepath.Join(c.root, "dev")); err != nil {
		return nil, err
	}
	if err := linkDevFiles(c.root, c.mounts); err != nil {
		return nil, err
	}
	if err := r.openLog(c); err != nil {
		return nil, err
	}

	cmd := &exec.Cmd{Path: path, Args: c.argv, Env: c.env, Dir: c.workdir}
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Chroot:     c.root,
		Credential: &syscall.Credential{Uid: uint32(s.addr.uid), Gid: uint32(s.addr.uid)},
		Setpgid:    true,
	}
	// Debugging knobs, by pod annotation, for telling which of the pieces a
	// failure comes from. Not a feature: each one takes an isolation away --
	// debug-host runs the command as root on the node itself -- so they are
	// honoured only on a node started with -debug-annotations. Without it, any
	// pod on a shared machine could annotate its way out of its chroot.
	if !r.debugAnnotations {
		for _, a := range []string{"ferry.dev/debug-root", "ferry.dev/debug-no-chroot", "ferry.dev/debug-host"} {
			if s.anns[a] == "true" {
				log.Printf("container %s: ignoring %s; this node was not started with -debug-annotations", c.id, a)
			}
		}
	}
	if r.debugAnnotations && s.anns["ferry.dev/debug-root"] == "true" {
		cmd.SysProcAttr.Credential = nil
	}
	if r.debugAnnotations && s.anns["ferry.dev/debug-no-chroot"] == "true" {
		cmd.SysProcAttr.Chroot = ""
		cmd.Path = filepath.Join(c.root, path)
		cmd.Dir = c.root
		cmd.Env = append(cmd.Env, "DYLD_INSERT_LIBRARIES="+filepath.Join(c.root, shimInRoot))
	}
	// The command as the node's own root process would run it: no chroot, no
	// uid, no shim, the runtime's environment. An absolute argv[0] is a node
	// path; a relative one is the image's binary.
	if r.debugAnnotations && s.anns["ferry.dev/debug-host"] == "true" {
		cmd.SysProcAttr.Chroot, cmd.SysProcAttr.Credential = "", nil
		cmd.Path, cmd.Dir, cmd.Env = c.argv[0], "/", os.Environ()
		if !strings.HasPrefix(c.argv[0], "/") {
			cmd.Path = filepath.Join(c.root, "bin", c.argv[0])
		}
	}
	if c.tty {
		return r.startTerminal(c, s, cmd)
	}

	// Through the reaper, with output to files: see reap.go and tail.go.
	spec := reapSpec{Path: cmd.Path, Argv: cmd.Args, Env: cmd.Env, Dir: cmd.Dir, Chroot: cmd.SysProcAttr.Chroot,
		UID: -1, Stdout: c.stdoutPath, Stderr: c.stderrPath,
		PidFile: filepath.Join(c.dir, "pid"), Exit: filepath.Join(c.dir, "exit")}
	if cr := cmd.SysProcAttr.Credential; cr != nil {
		spec.UID = int(cr.Uid)
	}
	_ = os.Remove(spec.Exit)
	var stdinR *os.File
	if c.openStdin {
		pr, pw, err := os.Pipe()
		if err != nil {
			c.clog.close()
			return nil, err
		}
		stdinR, c.stdin = pr, pw
	}
	proc, pid, err := startReaper(c.dir, spec, stdinR)
	if stdinR != nil {
		stdinR.Close()
	}
	if err != nil {
		c.clog.close()
		return nil, fmt.Errorf("start %v: %w", c.argv, err)
	}
	c.mu.Lock()
	c.state, c.started, c.done = runtimeapi.ContainerState_CONTAINER_RUNNING, time.Now().UnixNano(), make(chan struct{})
	c.pid, c.reaperPid = pid, proc.Pid
	c.mu.Unlock()
	r.saveContainer(c)
	log.Printf("container %s: started pid %d (reaper %d) as uid %d at %s (stdin %v)", c.id, pid, proc.Pid, s.addr.uid, s.addr.ip, c.openStdin)
	r.startWatchers(c)
	go r.follow(c)
	go r.waitReaper(c, proc)
	return &runtimeapi.StartContainerResponse{}, nil
}

// startTerminal runs a `tty: true` container the old way: the runtime's own
// child, on a pseudo-terminal the runtime holds. The terminal cannot outlive
// the runtime, so neither can the container; a restarted runtime reports it
// ended (state.go). Terminal containers are interactive, and short-lived.
func (r *runtimeSvc) startTerminal(c *container, s *sandbox, cmd *exec.Cmd) (*runtimeapi.StartContainerResponse, error) {
	c.cmd = cmd
	outputs, err := c.startStdio(cmd.Start, func() {
		// A terminal makes the process a session leader, which a process
		// group of its own already is; the two cannot both be asked for.
		cmd.SysProcAttr.Setpgid = false
		cmd.SysProcAttr.Setsid, cmd.SysProcAttr.Setctty = true, true
	})
	if err != nil {
		c.clog.close()
		return nil, fmt.Errorf("start %v: %w", c.argv, err)
	}
	c.mu.Lock()
	c.state, c.started, c.done = runtimeapi.ContainerState_CONTAINER_RUNNING, time.Now().UnixNano(), make(chan struct{})
	c.pid = cmd.Process.Pid
	c.mu.Unlock()
	r.saveContainer(c)
	log.Printf("container %s: started pid %d as uid %d at %s (tty)", c.id, c.pid, s.addr.uid, s.addr.ip)
	r.startWatchers(c)
	go func() {
		c.clog.pump("stdout", outputs[0], &c.fan)
		_ = cmd.Wait()
		rec := exitRecord{Code: int32(cmd.ProcessState.ExitCode()), Finished: time.Now().UnixNano()}
		if ws, ok := cmd.ProcessState.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			rec.Code = 128 + int32(ws.Signal())
		}
		r.finish(c, rec)
		c.clog.close()
	}()
	return &runtimeapi.StartContainerResponse{}, nil
}

func (r *runtimeSvc) startWatchers(c *container) {
	if c.memLimit > 0 {
		go r.watchMemory(c, c.pid)
	}
	if c.cpuQuota > 0 && c.cpuPeriod > 0 {
		go r.throttleCPU(c, c.pid)
	}
}

// waitReaper waits for a container's reaper -- as its parent when this runtime
// started it, by polling when it was adopted from an earlier one -- and records
// how the container ended.
func (r *runtimeSvc) waitReaper(c *container, proc *os.Process) {
	if proc != nil {
		_, _ = proc.Wait()
	} else {
		waitExit(c.reaperPid)
	}
	rec, ok := readExit(filepath.Join(c.dir, "exit"))
	if !ok {
		// The reaper went without saying: it was killed. Make sure the
		// container went with it.
		if alive(c.pid) {
			_ = syscall.Kill(-c.pid, syscall.SIGKILL)
		}
		rec = exitRecord{Code: 255, Finished: time.Now().UnixNano()}
	}
	r.finish(c, rec)
}

// finish records a container's end, once.
func (r *runtimeSvc) finish(c *container, rec exitRecord) {
	c.mu.Lock()
	if c.state == runtimeapi.ContainerState_CONTAINER_EXITED {
		c.mu.Unlock()
		return
	}
	c.state, c.finished, c.exit = runtimeapi.ContainerState_CONTAINER_EXITED, rec.Finished, rec.Code
	// No message of the runtime's own: the kubelet fills an empty one from the
	// container's termination-log file, and "exit status 3" here would be what
	// the user reads instead of what the container wrote.
	c.reason = "Completed"
	if c.exit != 0 {
		c.reason = "Error"
	}
	// The kubelet reads OOMKilled and backs the pod off as it would a cgroup
	// kill; without it a memory-killed container looks like any other exit.
	if c.oomKilled {
		c.reason = "OOMKilled"
	}
	close(c.done)
	c.mu.Unlock()
	unmountDev(c.root)
	r.saveContainer(c)
	log.Printf("container %s: exited %d", c.id, rec.Code)
}

// openLog opens the kubelet's log file for a container, appending.
func (r *runtimeSvc) openLog(c *container) error {
	if err := os.MkdirAll(filepath.Dir(c.logPath), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(c.logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o640)
	if err != nil {
		return err
	}
	c.clog = &criLog{f: f, path: c.logPath}
	return nil
}

// criLog writes a container's output in the format the kubelet reads back for
// `kubectl logs`: "<RFC3339Nano> <stream> F <line>".
type criLog struct {
	mu   sync.Mutex
	f    *os.File
	path string
}

// reopen starts a new file at the same path, after the kubelet has rotated the
// old one away (ReopenContainerLog).
func (l *criLog) reopen() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	f, err := os.OpenFile(l.path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o640)
	if err != nil {
		return err
	}
	if l.f != nil {
		l.f.Close()
	}
	l.f = f
	return nil
}

func (l *criLog) close() {
	if l == nil {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.f != nil {
		l.f.Close()
		l.f = nil
	}
}

func (c *container) stop(timeout time.Duration) {
	c.mu.Lock()
	pid, done, running := c.pid, c.done, c.state == runtimeapi.ContainerState_CONTAINER_RUNNING
	c.mu.Unlock()
	if !running || pid <= 0 {
		return
	}
	// SIGCONT first: the CPU throttle may have the group SIGSTOP'd, and a
	// stopped process does not act on SIGTERM until it is continued.
	_ = syscall.Kill(-pid, syscall.SIGCONT)
	_ = syscall.Kill(-pid, syscall.SIGTERM)
	select {
	case <-done:
	case <-time.After(timeout):
		_ = syscall.Kill(-pid, syscall.SIGKILL)
		<-done
	}
}

func (r *runtimeSvc) StopContainer(_ context.Context, req *runtimeapi.StopContainerRequest) (*runtimeapi.StopContainerResponse, error) {
	r.mu.Lock()
	c, ok := r.ctrs[req.ContainerId]
	r.mu.Unlock()
	if ok {
		t := time.Duration(req.Timeout) * time.Second
		if t <= 0 {
			t = 2 * time.Second
		}
		c.stop(t)
	}
	return &runtimeapi.StopContainerResponse{}, nil
}

func (r *runtimeSvc) RemoveContainer(_ context.Context, req *runtimeapi.RemoveContainerRequest) (*runtimeapi.RemoveContainerResponse, error) {
	r.mu.Lock()
	c, ok := r.ctrs[req.ContainerId]
	delete(r.ctrs, req.ContainerId)
	r.mu.Unlock()
	if ok {
		c.stop(2 * time.Second)
		// /dev is unmounted before the tree goes: removing a root with devfs
		// still on it would walk into the node's device nodes.
		unmountDev(c.root)
		unmountVolumes(c.root, c.mounts)
		if out, err := exec.Command("mount").Output(); err == nil && strings.Contains(string(out), c.root) {
			return nil, fmt.Errorf("container %s: %s is still mounted", c.id, c.root)
		}
		_ = os.RemoveAll(c.root)
		_ = os.RemoveAll(c.dir)
	}
	return &runtimeapi.RemoveContainerResponse{}, nil
}

func (r *runtimeSvc) status(c *container) *runtimeapi.ContainerStatus {
	c.mu.Lock()
	defer c.mu.Unlock()
	return &runtimeapi.ContainerStatus{
		Id: c.id, Metadata: c.meta, State: c.state,
		CreatedAt: c.made, StartedAt: c.started, FinishedAt: c.finished, ExitCode: c.exit,
		Reason: c.reason, Message: c.message,
		Image: &runtimeapi.ImageSpec{Image: c.image.id}, ImageRef: c.image.id, ImageId: c.image.id,
		Labels: c.labels, Annotations: c.anns, LogPath: c.logPath, Mounts: c.criMounts,
	}
}

func (r *runtimeSvc) ContainerStatus(_ context.Context, req *runtimeapi.ContainerStatusRequest) (*runtimeapi.ContainerStatusResponse, error) {
	r.mu.Lock()
	c, ok := r.ctrs[req.ContainerId]
	r.mu.Unlock()
	if !ok {
		return nil, fmt.Errorf("container %q not found", req.ContainerId)
	}
	return &runtimeapi.ContainerStatusResponse{Status: r.status(c)}, nil
}

func (r *runtimeSvc) ListContainers(_ context.Context, req *runtimeapi.ListContainersRequest) (*runtimeapi.ListContainersResponse, error) {
	r.mu.Lock()
	var all []*container
	for _, c := range r.ctrs {
		all = append(all, c)
	}
	r.mu.Unlock()
	f := req.GetFilter()
	var out []*runtimeapi.Container
	for _, c := range all {
		st := r.status(c)
		if f != nil {
			if f.Id != "" && f.Id != c.id {
				continue
			}
			if f.PodSandboxId != "" && f.PodSandboxId != c.sandboxID {
				continue
			}
			if w := f.GetState(); w != nil && w.State != st.State {
				continue
			}
			if !matchLabels(f.LabelSelector, c.labels) {
				continue
			}
		}
		out = append(out, &runtimeapi.Container{
			Id: c.id, PodSandboxId: c.sandboxID, Metadata: c.meta,
			Image: st.Image, ImageRef: st.ImageRef, ImageId: st.ImageId,
			State: st.State, CreatedAt: c.made, Labels: c.labels, Annotations: c.anns,
		})
	}
	return &runtimeapi.ListContainersResponse{Containers: out}, nil
}

// UpdateRuntimeConfig is how the kubelet passes on the pod CIDR
// kube-controller-manager gave this node.
func (r *runtimeSvc) UpdateRuntimeConfig(_ context.Context, req *runtimeapi.UpdateRuntimeConfigRequest) (*runtimeapi.UpdateRuntimeConfigResponse, error) {
	if err := r.node.setPodCIDR(req.GetRuntimeConfig().GetNetworkConfig().GetPodCidr()); err != nil {
		return nil, err
	}
	// Saved: the kubelet sends this once, when the CIDR changes, and would not
	// send it again to a restarted runtime.
	r.saveRuntime()
	return &runtimeapi.UpdateRuntimeConfigResponse{}, nil
}

func (r *runtimeSvc) RuntimeConfig(_ context.Context, _ *runtimeapi.RuntimeConfigRequest) (*runtimeapi.RuntimeConfigResponse, error) {
	return &runtimeapi.RuntimeConfigResponse{}, nil
}

// ReopenContainerLog is the kubelet's log rotation: it has renamed the file,
// and wants writing to carry on in a new one at the old path.
func (r *runtimeSvc) ReopenContainerLog(_ context.Context, req *runtimeapi.ReopenContainerLogRequest) (*runtimeapi.ReopenContainerLogResponse, error) {
	r.mu.Lock()
	c, ok := r.ctrs[req.ContainerId]
	r.mu.Unlock()
	if !ok {
		return nil, fmt.Errorf("container %q not found", req.ContainerId)
	}
	if c.clog == nil {
		return nil, fmt.Errorf("container %s is not running", req.ContainerId)
	}
	if err := c.clog.reopen(); err != nil {
		return nil, err
	}
	return &runtimeapi.ReopenContainerLogResponse{}, nil
}

// containerStats reads a running container's process group: cumulative CPU and
// current memory, the counters the summary API and metrics-server want. A
// container that is not running reports its attributes and no numbers, which is
// what a Linux runtime does for one whose cgroup is gone.
func (r *runtimeSvc) containerStats(c *container) *runtimeapi.ContainerStats {
	c.mu.Lock()
	state, pid := c.state, c.pid
	c.mu.Unlock()
	now := time.Now().UnixNano()
	stats := &runtimeapi.ContainerStats{
		Attributes: &runtimeapi.ContainerAttributes{
			Id: c.id, Metadata: c.meta, Labels: c.labels, Annotations: c.anns,
		},
		Cpu:    &runtimeapi.CpuUsage{Timestamp: now},
		Memory: &runtimeapi.MemoryUsage{Timestamp: now},
	}
	if state == runtimeapi.ContainerState_CONTAINER_RUNNING && pid > 0 {
		// The pid is the process group's id: the container leads its own group
		// (Setpgid, in the reaper), and everything it spawns is in it.
		if cpu, mem, ok := procStats(pid); ok {
			stats.Cpu.UsageCoreNanoSeconds = &runtimeapi.UInt64Value{Value: cpu}
			stats.Memory.WorkingSetBytes = &runtimeapi.UInt64Value{Value: mem}
			stats.Memory.UsageBytes = &runtimeapi.UInt64Value{Value: mem}
		}
	}
	return stats
}

// watchMemory is the OOM killer macOS does not give a chroot: it polls the
// container's process group and, when its footprint passes the pod's limit,
// kills the group and marks it OOMKilled. cgroups would do this in the kernel
// and count page cache; this counts phys_footprint (anonymous + compressed +
// wired, what a pod actually holds) and polls, so a burst faster than the
// interval can overshoot briefly -- enough to keep one pod from taking the
// machine down, not a hard barrier.
func (r *runtimeSvc) watchMemory(c *container, pgid int) {
	const interval = 250 * time.Millisecond
	for {
		select {
		case <-c.done:
			return
		case <-time.After(interval):
		}
		_, mem, ok := procStats(pgid)
		if !ok {
			return // the group is gone; Wait will record the exit
		}
		if int64(mem) <= c.memLimit {
			continue
		}
		c.mu.Lock()
		c.oomKilled = true
		c.mu.Unlock()
		log.Printf("container %s: OOMKilled -- %d MiB over its %d MiB limit", c.id, int64(mem)/(1<<20), c.memLimit/(1<<20))
		_ = syscall.Kill(-pgid, syscall.SIGKILL)
		return
	}
}

// throttleCPU is the CFS quota macOS does not give a chroot. It measures the
// group's CPU each window and, when it has spent more than its share, SIGSTOPs
// the group for long enough to bring the average back to the limit, then
// SIGCONTs -- the duty cycle userspace cpulimit uses. It is coarser than the
// kernel's per-runqueue throttling (a whole group pauses for milliseconds at a
// time) and, being a poll, holds the average near the limit rather than
// enforcing it instant to instant. A container under its limit is never
// signalled.
func (r *runtimeSvc) throttleCPU(c *container, pgid int) {
	cores := float64(c.cpuQuota) / float64(c.cpuPeriod)
	if cores <= 0 {
		return
	}
	const window = 100 * time.Millisecond
	baseCPU, _, ok := procStats(pgid)
	if !ok {
		return
	}
	baseT := time.Now()
	for {
		select {
		case <-c.done:
			return
		case <-time.After(window):
		}
		cpu, _, ok := procStats(pgid)
		if !ok {
			return
		}
		now := time.Now()
		elapsed := now.Sub(baseT)
		used := time.Duration(cpu - baseCPU) // CPU-nanoseconds since the baseline
		baseCPU, baseT = cpu, now
		budget := time.Duration(float64(elapsed) * cores)
		if used <= budget || elapsed <= 0 {
			continue
		}
		// Pause so that used / (elapsed + pause) == cores.
		pause := time.Duration(float64(used)/cores) - elapsed
		if pause <= 0 {
			continue
		}
		if pause > time.Second {
			pause = time.Second // a long pause is a stuck pod, not a throttle
		}
		_ = syscall.Kill(-pgid, syscall.SIGSTOP)
		select {
		case <-c.done:
			_ = syscall.Kill(-pgid, syscall.SIGCONT)
			return
		case <-time.After(pause):
		}
		_ = syscall.Kill(-pgid, syscall.SIGCONT)
		// Start the next window from here, so the stopped time is not counted
		// against the group as idle-but-owed.
		if cpu2, _, ok := procStats(pgid); ok {
			baseCPU, baseT = cpu2, time.Now()
		}
	}
}

func (r *runtimeSvc) ContainerStats(_ context.Context, req *runtimeapi.ContainerStatsRequest) (*runtimeapi.ContainerStatsResponse, error) {
	r.mu.Lock()
	c, ok := r.ctrs[req.ContainerId]
	r.mu.Unlock()
	if !ok {
		return nil, fmt.Errorf("container %q not found", req.ContainerId)
	}
	return &runtimeapi.ContainerStatsResponse{Stats: r.containerStats(c)}, nil
}

func (r *runtimeSvc) ListContainerStats(_ context.Context, req *runtimeapi.ListContainerStatsRequest) (*runtimeapi.ListContainerStatsResponse, error) {
	r.mu.Lock()
	var all []*container
	for _, c := range r.ctrs {
		all = append(all, c)
	}
	r.mu.Unlock()
	f := req.GetFilter()
	var out []*runtimeapi.ContainerStats
	for _, c := range all {
		if f != nil {
			if f.Id != "" && f.Id != c.id {
				continue
			}
			if f.PodSandboxId != "" && f.PodSandboxId != c.sandboxID {
				continue
			}
			if !matchLabels(f.LabelSelector, c.labels) {
				continue
			}
		}
		out = append(out, r.containerStats(c))
	}
	return &runtimeapi.ListContainerStatsResponse{Stats: out}, nil
}

// podStats sums a sandbox's containers into pod-level CPU and memory. Without
// cgroups there is no pod accounting of its own -- a pod is not a process here,
// only its containers are -- so the pod's numbers are its containers' summed,
// which for a macOS pod (usually one container) is the same thing.
func (r *runtimeSvc) podStats(s *sandbox, ctrs []*container) *runtimeapi.PodSandboxStats {
	now := time.Now().UnixNano()
	var cpu, mem uint64
	var have bool
	containers := make([]*runtimeapi.ContainerStats, 0, len(ctrs))
	for _, c := range ctrs {
		cs := r.containerStats(c)
		containers = append(containers, cs)
		if cs.Cpu.GetUsageCoreNanoSeconds() != nil {
			cpu += cs.Cpu.UsageCoreNanoSeconds.Value
			have = true
		}
		if cs.Memory.GetWorkingSetBytes() != nil {
			mem += cs.Memory.WorkingSetBytes.Value
			have = true
		}
	}
	linux := &runtimeapi.LinuxPodSandboxStats{
		Cpu:        &runtimeapi.CpuUsage{Timestamp: now},
		Memory:     &runtimeapi.MemoryUsage{Timestamp: now},
		Containers: containers,
	}
	if have {
		linux.Cpu.UsageCoreNanoSeconds = &runtimeapi.UInt64Value{Value: cpu}
		linux.Memory.WorkingSetBytes = &runtimeapi.UInt64Value{Value: mem}
		linux.Memory.UsageBytes = &runtimeapi.UInt64Value{Value: mem}
	}
	return &runtimeapi.PodSandboxStats{
		Attributes: &runtimeapi.PodSandboxAttributes{
			Id: s.id, Metadata: s.meta, Labels: s.labels, Annotations: s.anns,
		},
		Linux: linux,
	}
}

// containersOf is a sandbox's containers, under the runtime lock.
func (r *runtimeSvc) containersOf(sandboxID string) []*container {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []*container
	for _, c := range r.ctrs {
		if c.sandboxID == sandboxID {
			out = append(out, c)
		}
	}
	return out
}

func (r *runtimeSvc) PodSandboxStats(_ context.Context, req *runtimeapi.PodSandboxStatsRequest) (*runtimeapi.PodSandboxStatsResponse, error) {
	r.mu.Lock()
	s, ok := r.sboxes[req.PodSandboxId]
	r.mu.Unlock()
	if !ok {
		return nil, fmt.Errorf("sandbox %q not found", req.PodSandboxId)
	}
	return &runtimeapi.PodSandboxStatsResponse{Stats: r.podStats(s, r.containersOf(s.id))}, nil
}

func (r *runtimeSvc) ListPodSandboxStats(_ context.Context, req *runtimeapi.ListPodSandboxStatsRequest) (*runtimeapi.ListPodSandboxStatsResponse, error) {
	r.mu.Lock()
	var all []*sandbox
	for _, s := range r.sboxes {
		all = append(all, s)
	}
	r.mu.Unlock()
	f := req.GetFilter()
	var out []*runtimeapi.PodSandboxStats
	for _, s := range all {
		if f != nil {
			if f.Id != "" && f.Id != s.id {
				continue
			}
			if !matchLabels(f.LabelSelector, s.labels) {
				continue
			}
		}
		out = append(out, r.podStats(s, r.containersOf(s.id)))
	}
	return &runtimeapi.ListPodSandboxStatsResponse{Stats: out}, nil
}
func (r *runtimeSvc) ListMetricDescriptors(_ context.Context, _ *runtimeapi.ListMetricDescriptorsRequest) (*runtimeapi.ListMetricDescriptorsResponse, error) {
	return &runtimeapi.ListMetricDescriptorsResponse{}, nil
}
func (r *runtimeSvc) ListPodSandboxMetrics(_ context.Context, _ *runtimeapi.ListPodSandboxMetricsRequest) (*runtimeapi.ListPodSandboxMetricsResponse, error) {
	return &runtimeapi.ListPodSandboxMetricsResponse{}, nil
}

func matchLabels(want, have map[string]string) bool {
	for k, v := range want {
		if have[k] != v {
			return false
		}
	}
	return true
}

// defaultPath is macOS's own, from /etc/paths: a pod whose image sets no
// PATH finds sysctl and ifconfig where a Mac's shell does.
const defaultPath = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
