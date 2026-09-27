package main

// Keeping a container's exit status when the runtime is not there to see it.
//
// A container used to be the runtime's own child, so its exit status went to
// the runtime's Wait -- and when the runtime died, the container was re-parented
// to launchd, which collected the status and threw it away. A Job's pod that
// finished while the runtime was down could not say whether it had succeeded.
//
// So a container is started through `ferry-darwin reap SPEC`: a process that
// does nothing but start the container as its child, wait for it, and write
// what it returned to a file. It has no pipes of the container's -- output goes
// straight to files (see tail.go) -- so there is nothing in it that needs the
// runtime alive. It runs in a session of its own, outside the container's
// process group, so signals meant for the container do not reach it.

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// reapSpec is what the reaper is told to run.
type reapSpec struct {
	Path    string   `json:"path"`
	Argv    []string `json:"argv"`
	Env     []string `json:"env"`
	Dir     string   `json:"dir"`
	Chroot  string   `json:"chroot"`
	UID     int      `json:"uid"` // -1: as root, without changing credentials
	Stdout  string   `json:"stdout"`
	Stderr  string   `json:"stderr"`
	PidFile string   `json:"pidFile"`
	Exit    string   `json:"exit"`
}

// exitRecord is what a finished container left behind.
type exitRecord struct {
	Code     int32 `json:"code"`
	Finished int64 `json:"finished"`
}

// runReaper is `ferry-darwin reap SPEC`. Its stdin is the container's; fd 3 is
// where it reports "ok <pid>" once the container runs, or why it could not.
func runReaper(specPath string) {
	report := os.NewFile(3, "report")
	fail := func(err error) {
		if report != nil {
			fmt.Fprintf(report, "err %v\n", err)
		}
		os.Exit(1)
	}
	var spec reapSpec
	b, err := os.ReadFile(specPath)
	if err != nil {
		fail(err)
	}
	if err := json.Unmarshal(b, &spec); err != nil {
		fail(err)
	}
	stdout, err := os.OpenFile(spec.Stdout, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o640)
	if err != nil {
		fail(err)
	}
	stderr, err := os.OpenFile(spec.Stderr, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o640)
	if err != nil {
		fail(err)
	}
	cmd := &exec.Cmd{Path: spec.Path, Args: spec.Argv, Env: spec.Env, Dir: spec.Dir,
		Stdin: os.Stdin, Stdout: stdout, Stderr: stderr}
	cmd.SysProcAttr = &syscall.SysProcAttr{Chroot: spec.Chroot, Setpgid: true}
	if spec.UID >= 0 {
		cmd.SysProcAttr.Credential = &syscall.Credential{Uid: uint32(spec.UID), Gid: uint32(spec.UID)}
	}
	if err := cmd.Start(); err != nil {
		fail(err)
	}
	_ = writeFileAtomic(spec.PidFile, []byte(strconv.Itoa(cmd.Process.Pid)))
	fmt.Fprintf(report, "ok %d\n", cmd.Process.Pid)
	report.Close()
	os.Stdin.Close() // the container has its own copy; the reaper keeps no end of it

	_ = cmd.Wait()
	rec := exitRecord{Code: int32(cmd.ProcessState.ExitCode()), Finished: time.Now().UnixNano()}
	if ws, ok := cmd.ProcessState.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		rec.Code = 128 + int32(ws.Signal())
	}
	out, _ := json.Marshal(rec)
	_ = writeFileAtomic(spec.Exit, out)
}

// startReaper runs a container through the reaper and returns the reaper's
// process and the container's pid once it is running.
func startReaper(dir string, spec reapSpec, stdin *os.File) (*os.Process, int, error) {
	specPath := filepath.Join(dir, "reap.json")
	b, _ := json.Marshal(spec)
	if err := writeFileAtomic(specPath, b); err != nil {
		return nil, 0, err
	}
	self, err := os.Executable()
	if err != nil {
		return nil, 0, err
	}
	rd, wr, err := os.Pipe()
	if err != nil {
		return nil, 0, err
	}
	defer rd.Close()
	cmd := exec.Command(self, "reap", specPath)
	cmd.Stdin = stdin
	if stdin == nil {
		devnull, _ := os.Open(os.DevNull)
		defer devnull.Close()
		cmd.Stdin = devnull
	}
	cmd.ExtraFiles = []*os.File{wr}
	// Its own session: out of the runtime's process group, which launchd may
	// signal when it restarts the runtime, and out of the container's.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		wr.Close()
		return nil, 0, err
	}
	wr.Close()
	line := make([]byte, 4096)
	n, _ := rd.Read(line)
	msg := strings.TrimSpace(string(line[:n]))
	if pid, ok := strings.CutPrefix(msg, "ok "); ok {
		p, err := strconv.Atoi(pid)
		if err != nil {
			return nil, 0, fmt.Errorf("reaper: %q", msg)
		}
		return cmd.Process, p, nil
	}
	_ = cmd.Wait()
	if e, ok := strings.CutPrefix(msg, "err "); ok {
		return nil, 0, fmt.Errorf("%s", e)
	}
	return nil, 0, fmt.Errorf("reaper exited without starting the container")
}

// readExit is a finished container's record, if its reaper wrote one.
func readExit(path string) (exitRecord, bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return exitRecord{}, false
	}
	var rec exitRecord
	if json.Unmarshal(b, &rec) != nil {
		return exitRecord{}, false
	}
	return rec, true
}

// isOurs is whether pid is a ferry-darwin process of the given kind ("reap",
// "pvserve") -- checked before adopting one, since a pid in a record can have
// been reused by something else since.
func isOurs(pid int, kind string) bool {
	if !alive(pid) {
		return false
	}
	out, err := exec.Command("ps", "-o", "args=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return false
	}
	f := strings.Fields(string(out))
	return len(f) >= 2 && filepath.Base(f[0]) == "ferry-darwin" && f[1] == kind
}

// waitExit blocks until a process that is not our child exits: kqueue's
// NOTE_EXIT notifies for any process, where wait(2) is only for children.
func waitExit(pid int) {
	kq, err := syscall.Kqueue()
	if err != nil {
		for alive(pid) {
			time.Sleep(500 * time.Millisecond)
		}
		return
	}
	defer syscall.Close(kq)
	ev := syscall.Kevent_t{Ident: uint64(pid), Filter: syscall.EVFILT_PROC,
		Flags: syscall.EV_ADD | syscall.EV_ONESHOT, Fflags: syscall.NOTE_EXIT}
	if _, err := syscall.Kevent(kq, []syscall.Kevent_t{ev}, nil, nil); err != nil {
		return // ESRCH: already gone
	}
	out := make([]syscall.Kevent_t, 1)
	for {
		n, err := syscall.Kevent(kq, nil, out, nil)
		if err == syscall.EINTR {
			continue
		}
		if err != nil || n > 0 {
			return
		}
	}
}

// alive is whether a process exists: signal 0 checks without sending.
func alive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || err == syscall.EPERM
}

// writeFileAtomic writes to a temporary file of its own and renames it into
// place. Its own: two saves of the same record at once (the tailer's and a
// state change's) once shared one ".tmp" name, and the second rename failed.
func writeFileAtomic(path string, b []byte) error {
	f, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".*.tmp")
	if err != nil {
		return err
	}
	tmp := f.Name()
	if _, err := f.Write(b); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	_ = os.Chmod(tmp, 0o644)
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}
