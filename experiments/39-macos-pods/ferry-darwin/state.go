package main

// The runtime's state on disk, so a restarted ferry-darwin knows its pods.
//
// Everything the kubelet has been told -- sandbox and container ids, their
// states, when they started and how they ended -- used to live in two maps and
// die with the process. A new process then answered "no sandboxes", and the
// kubelet made every pod again beside the old ones, still running with the
// same addresses. Now each sandbox and container is also a small JSON record,
// rewritten whenever it changes, and restore() reads them back at start:
//
//	<state>/runtime.json              id counter, address counter, pod CIDR, boot
//	<state>/pods/<sb>/sandbox.json    a sandbox
//	<state>/pods/<sb>/<ctr>.d/        a container: container.json, its output
//	                                  files, and the reaper's pid and exit record
//
// A record from an earlier boot is discarded rather than believed: the
// processes, addresses and mounts it describes went with the reboot.

import (
	"encoding/json"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	runtimeapi "k8s.io/cri-api/pkg/apis/runtime/v1"
)

type runtimeRecord struct {
	Boot       string `json:"boot"`
	N          int    `json:"n"`
	NextN      int    `json:"nextN"`
	PodCIDR    string `json:"podCIDR"`
	PodVMOwner string `json:"podVMOwner"`
}

type sandboxRecord struct {
	ID        string            `json:"id"`
	Name      string            `json:"name"`
	UID       string            `json:"uid"`
	Namespace string            `json:"namespace"`
	Attempt   uint32            `json:"attempt"`
	Labels    map[string]string `json:"labels"`
	Anns      map[string]string `json:"annotations"`
	LogDir    string            `json:"logDir"`
	IP        string            `json:"ip"`
	PodUID    int               `json:"podUid"`
	Made      int64             `json:"made"`
	Ready     bool              `json:"ready"`
}

type volumeRecord struct {
	Host     string `json:"host"`
	Path     string `json:"path"`
	ReadOnly bool   `json:"readOnly"`
	File     bool   `json:"file"`
}

type criMountRecord struct {
	ContainerPath string `json:"containerPath"`
	HostPath      string `json:"hostPath"`
	Readonly      bool   `json:"readonly"`
}

type containerRecord struct {
	ID         string            `json:"id"`
	SandboxID  string            `json:"sandboxId"`
	Name       string            `json:"name"`
	Attempt    uint32            `json:"attempt"`
	ImageID    string            `json:"imageId"`
	Labels     map[string]string `json:"labels"`
	Anns       map[string]string `json:"annotations"`
	LogPath    string            `json:"logPath"`
	Root       string            `json:"root"`
	Argv       []string          `json:"argv"`
	Env        []string          `json:"env"`
	Workdir    string            `json:"workdir"`
	Mounts     []volumeRecord    `json:"mounts"`
	CRIMounts  []criMountRecord  `json:"criMounts"`
	MemLimit   int64             `json:"memLimit"`
	CPUQuota   int64             `json:"cpuQuota"`
	CPUPeriod  int64             `json:"cpuPeriod"`
	TTY        bool              `json:"tty"`
	OpenStdin  bool              `json:"openStdin"`
	StdinOnce  bool              `json:"stdinOnce"`
	State      int32             `json:"state"`
	Made       int64             `json:"made"`
	Started    int64             `json:"started"`
	Finished   int64             `json:"finished"`
	Exit       int32             `json:"exit"`
	Reason     string            `json:"reason"`
	OOMKilled  bool              `json:"oomKilled"`
	Pid        int               `json:"pid"`
	ReaperPid  int               `json:"reaperPid"`
	LogOffsets [2]int64          `json:"logOffsets"`
}

func bootSession() string {
	out, _ := exec.Command("sysctl", "-n", "kern.bootsessionuuid").Output()
	return strings.TrimSpace(string(out))
}

func (r *runtimeSvc) sandboxDir(id string) string { return filepath.Join(r.node.state, "pods", id) }

// containerDir is a container's own directory, beside its root: the root is
// what the container sees, and none of this should be in it.
func (r *runtimeSvc) containerDir(sandboxID, id string) string {
	return filepath.Join(r.node.state, "pods", sandboxID, id+".d")
}

func saveJSON(path string, v any) {
	b, err := json.Marshal(v)
	if err == nil {
		err = writeFileAtomic(path, b)
	}
	if err != nil {
		log.Printf("state: writing %s: %v", path, err)
	}
}

func (r *runtimeSvc) saveRuntime() {
	r.mu.Lock()
	rec := runtimeRecord{Boot: r.boot, N: r.n, PodVMOwner: r.podVMOwner}
	r.mu.Unlock()
	r.node.mu.Lock()
	rec.NextN = r.node.nextN
	if r.node.slice != nil {
		rec.PodCIDR = r.node.slice.String()
	}
	r.node.mu.Unlock()
	saveJSON(filepath.Join(r.node.state, "runtime.json"), rec)
}

func (r *runtimeSvc) saveSandbox(s *sandbox) {
	rec := sandboxRecord{ID: s.id, Labels: s.labels, Anns: s.anns, LogDir: s.logDir,
		IP: s.addr.ip, PodUID: s.addr.uid, Made: s.made, Ready: s.ready}
	if m := s.meta; m != nil {
		rec.Name, rec.UID, rec.Namespace, rec.Attempt = m.Name, m.Uid, m.Namespace, m.Attempt
	}
	saveJSON(filepath.Join(r.sandboxDir(s.id), "sandbox.json"), rec)
}

func (r *runtimeSvc) saveContainer(c *container) {
	c.mu.Lock()
	rec := containerRecord{ID: c.id, SandboxID: c.sandboxID, ImageID: c.image.id,
		Labels: c.labels, Anns: c.anns, LogPath: c.logPath, Root: c.root, Argv: c.argv, Env: c.env,
		Workdir: c.workdir, MemLimit: c.memLimit, CPUQuota: c.cpuQuota, CPUPeriod: c.cpuPeriod,
		TTY: c.tty, OpenStdin: c.openStdin, StdinOnce: c.stdinOnce,
		State: int32(c.state), Made: c.made, Started: c.started, Finished: c.finished,
		Exit: c.exit, Reason: c.reason, OOMKilled: c.oomKilled,
		Pid: c.pid, ReaperPid: c.reaperPid, LogOffsets: c.logOffsets}
	if m := c.meta; m != nil {
		rec.Name, rec.Attempt = m.Name, m.Attempt
	}
	for _, v := range c.mounts {
		rec.Mounts = append(rec.Mounts, volumeRecord{Host: v.host, Path: v.path, ReadOnly: v.readOnly, File: v.file})
	}
	for _, m := range c.criMounts {
		rec.CRIMounts = append(rec.CRIMounts, criMountRecord{ContainerPath: m.ContainerPath, HostPath: m.HostPath, Readonly: m.Readonly})
	}
	dir := c.dir
	c.mu.Unlock()
	if dir == "" {
		return
	}
	if _, err := os.Stat(dir); err != nil {
		return // removed (RemoveContainer); a late save must not bring it back
	}
	saveJSON(filepath.Join(dir, "container.json"), rec)
}

// restore reads the records back. It runs before the CRI is served and before
// pf is loaded, so the kubelet never sees an empty runtime and a pod's address
// is never left without its rules.
func (r *runtimeSvc) restore() {
	r.boot = bootSession()
	pods := filepath.Join(r.node.state, "pods")
	var rec runtimeRecord
	b, err := os.ReadFile(filepath.Join(r.node.state, "runtime.json"))
	if err != nil || json.Unmarshal(b, &rec) != nil || rec.Boot != r.boot {
		// No record, or one from an earlier boot: nothing it describes is here.
		entries, _ := os.ReadDir(pods)
		for _, e := range entries {
			_ = os.RemoveAll(filepath.Join(pods, e.Name()))
		}
		if len(entries) > 0 {
			log.Printf("state: %d sandboxes from an earlier boot discarded", len(entries))
		}
		r.saveRuntime()
		return
	}
	r.n, r.podVMOwner = rec.N, rec.PodVMOwner
	r.node.nextN = rec.NextN
	if rec.PodCIDR != "" {
		if err := r.node.setPodCIDR(rec.PodCIDR); err != nil {
			log.Printf("state: pod CIDR %s: %v", rec.PodCIDR, err)
		}
	}

	sbs, _ := filepath.Glob(filepath.Join(pods, "*", "sandbox.json"))
	for _, p := range sbs {
		var sr sandboxRecord
		if b, err := os.ReadFile(p); err != nil || json.Unmarshal(b, &sr) != nil {
			continue
		}
		s := &sandbox{id: sr.ID, labels: sr.Labels, anns: sr.Anns, logDir: sr.LogDir,
			addr: podAddr{ip: sr.IP, uid: sr.PodUID}, made: sr.Made, ready: sr.Ready,
			meta: &runtimeapi.PodSandboxMetadata{Name: sr.Name, Uid: sr.UID, Namespace: sr.Namespace, Attempt: sr.Attempt}}
		r.sboxes[s.id] = s
		if s.ready {
			// The alias and its route are kernel state and outlived the old
			// process; putting them again is harmless and covers a half-made one.
			r.node.pods[s.id] = s.addr
			_ = run("ifconfig", r.node.iface, "alias", s.addr.ip, "255.255.255.255")
			_ = run("route", "-q", "-n", "add", "-host", s.addr.ip, "-interface", "lo0")
		}
	}

	ctrs, _ := filepath.Glob(filepath.Join(pods, "*", "*.d", "container.json"))
	adopted, finished := 0, 0
	for _, p := range ctrs {
		var cr containerRecord
		if b, err := os.ReadFile(p); err != nil || json.Unmarshal(b, &cr) != nil {
			continue
		}
		if _, ok := r.sboxes[cr.SandboxID]; !ok {
			continue
		}
		c := r.containerFromRecord(cr, filepath.Dir(p))
		r.ctrs[c.id] = c
		if c.state != runtimeapi.ContainerState_CONTAINER_RUNNING {
			if c.state == runtimeapi.ContainerState_CONTAINER_EXITED {
				c.done = closedChan()
			}
			continue
		}
		if ex, ok := readExit(filepath.Join(c.dir, "exit")); ok {
			// It finished while the runtime was down; its reaper kept the status.
			// Its output files still hold what it wrote since the last save.
			c.done = make(chan struct{})
			r.openLog(c)
			go r.follow(c)
			r.finish(c, ex)
			finished++
			continue
		}
		if isOurs(c.reaperPid, "reap") {
			// Its reaper is still running (tty or not), holding its terminal,
			// stdin and output; the runtime picks the follow and the wait back
			// up, and reopens the stdin end attach writes to.
			c.done = make(chan struct{})
			r.openLog(c)
			if c.openStdin {
				r.openStdin(c)
			}
			go r.follow(c)
			go r.waitReaper(c, nil)
			if c.memLimit > 0 {
				go r.watchMemory(c, c.pid)
			}
			if c.cpuQuota > 0 && c.cpuPeriod > 0 {
				go r.throttleCPU(c, c.pid)
			}
			adopted++
			continue
		}
		// Gone without a record -- a reaper that was killed. Make sure nothing of
		// it is left running, and say it ended without knowing how.
		if alive(c.pid) {
			_ = syscall.Kill(-c.pid, syscall.SIGKILL)
		}
		c.done = make(chan struct{})
		r.finish(c, exitRecord{Code: 255, Finished: time.Now().UnixNano()})
		c.mu.Lock()
		c.reason = "Unknown"
		c.mu.Unlock()
		r.saveContainer(c)
		finished++
	}
	// Ids are handed out past the highest one on disk, whatever the counter says.
	for id := range r.sboxes {
		r.n = maxIDNumber(r.n, id)
	}
	for id := range r.ctrs {
		r.n = maxIDNumber(r.n, id)
	}
	r.saveRuntime()
	log.Printf("state: restored %d sandboxes, %d containers (%d running adopted, %d ended while the runtime was down)",
		len(r.sboxes), len(r.ctrs), adopted, finished)
}

func (r *runtimeSvc) containerFromRecord(cr containerRecord, dir string) *container {
	img := r.images.byID(cr.ImageID)
	c := &container{id: cr.ID, sandboxID: cr.SandboxID, image: img,
		meta:   &runtimeapi.ContainerMetadata{Name: cr.Name, Attempt: cr.Attempt},
		labels: cr.Labels, anns: cr.Anns, logPath: cr.LogPath, root: cr.Root, argv: cr.Argv, env: cr.Env,
		workdir: cr.Workdir, memLimit: cr.MemLimit, cpuQuota: cr.CPUQuota, cpuPeriod: cr.CPUPeriod,
		tty: cr.TTY, openStdin: cr.OpenStdin, stdinOnce: cr.StdinOnce,
		state: runtimeapi.ContainerState(cr.State), made: cr.Made, started: cr.Started, finished: cr.Finished,
		exit: cr.Exit, reason: cr.Reason, oomKilled: cr.OOMKilled,
		pid: cr.Pid, reaperPid: cr.ReaperPid, logOffsets: cr.LogOffsets, dir: dir,
		stdoutPath: filepath.Join(dir, "stdout"), stderrPath: filepath.Join(dir, "stderr")}
	if cr.OpenStdin {
		c.stdinPath = filepath.Join(dir, "stdin")
	}
	if cr.TTY {
		// The terminal device path the reaper wrote; still valid while the
		// reaper holds it, this boot.
		if b, err := os.ReadFile(filepath.Join(dir, "tty")); err == nil {
			c.ttyPath = strings.TrimSpace(string(b))
		}
	}
	for _, v := range cr.Mounts {
		c.mounts = append(c.mounts, volumeMount{host: v.Host, path: v.Path, readOnly: v.ReadOnly, file: v.File})
	}
	for _, m := range cr.CRIMounts {
		c.criMounts = append(c.criMounts, &runtimeapi.Mount{ContainerPath: m.ContainerPath, HostPath: m.HostPath, Readonly: m.Readonly})
	}
	return c
}

func maxIDNumber(n int, id string) int {
	if i := strings.LastIndexByte(id, '-'); i >= 0 {
		if v, err := strconv.Atoi(id[i+1:]); err == nil && v > n {
			return v
		}
	}
	return n
}

func closedChan() chan struct{} {
	ch := make(chan struct{})
	close(ch)
	return ch
}
