package main

// Keeping a container's exit status when the runtime is not there to see it.
//
// A container used to be the runtime's own child, so its exit status went to
// the runtime's Wait -- and when the runtime died, the container was re-parented
// to launchd, which collected the status and threw it away. A Job's pod that
// finished while the runtime was down could not say whether it had succeeded.
//
// So a container is started through `ferry-darwin reap SPEC`: a process that
// starts the container as its child, waits for it, and writes what it returned
// to a file. Output goes to files (tail.go), not through the reaper, so there is
// nothing in it that needs the runtime alive; it runs in a session of its own,
// so signals meant for the container do not reach it.
//
// It also holds the ends of a container's stdio that cannot be plain files, so
// those too outlive a runtime restart:
//
//	stdin     a named pipe the reaper keeps open read-write, so it never sees
//	          end-of-input when a runtime writing into it goes away; the reaper
//	          copies it to the child. SIGUSR1 (stdinOnce) closes the child's
//	          input so it reads EOF.
//	terminal  for tty containers, the pseudo-terminal's controlling end, which
//	          used to be the runtime's -- so the container was hung up (SIGHUP)
//	          when the runtime died. The reaper copies it to the output file and
//	          the stdin pipe into it; the runtime resizes it by device path,
//	          without holding it.

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/creack/pty"
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
	Stdin   string   `json:"stdin"`   // a named pipe, or "" for no input
	TTY     bool     `json:"tty"`     // run on a pseudo-terminal
	TTYFile string   `json:"ttyFile"` // where the terminal's device path is written
	PidFile string   `json:"pidFile"`
	Exit    string   `json:"exit"`
}

// exitRecord is what a finished container left behind.
type exitRecord struct {
	Code     int32 `json:"code"`
	Finished int64 `json:"finished"`
}

// runReaper is `ferry-darwin reap SPEC`. fd 3 is where it reports "ok <pid>"
// once the container runs, or why it could not.
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
	// Both output files exist for the runtime to follow, even a terminal's,
	// whose stderr stays empty because a terminal is one stream.
	stdout, err := os.OpenFile(spec.Stdout, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o640)
	if err != nil {
		fail(err)
	}
	stderr, err := os.OpenFile(spec.Stderr, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o640)
	if err != nil {
		fail(err)
	}
	// The input pipe, held open read-write so the reader never sees end-of-input
	// when a runtime that was writing into it goes away.
	var fifo *os.File
	if spec.Stdin != "" {
		if fifo, err = os.OpenFile(spec.Stdin, os.O_RDWR, 0); err != nil {
			fail(err)
		}
	}

	cmd := &exec.Cmd{Path: spec.Path, Args: spec.Argv, Env: spec.Env, Dir: spec.Dir}
	cmd.SysProcAttr = &syscall.SysProcAttr{Chroot: spec.Chroot}
	if spec.UID >= 0 {
		cmd.SysProcAttr.Credential = &syscall.Credential{Uid: uint32(spec.UID), Gid: uint32(spec.UID)}
	}

	var master *os.File     // the terminal end the reaper keeps
	var closeInput func()   // ends the container's input (stdinOnce)
	var childStdin *os.File // the reaper's copy of the child's stdin, to close after start

	if spec.TTY {
		m, slave, err := pty.Open()
		if err != nil {
			fail(err)
		}
		master = m
		// The slave is the child's three streams and its controlling terminal.
		// A session leader leads its own process group, so the child's pid is
		// still its group id -- Setsid instead of Setpgid, not both.
		cmd.Stdin, cmd.Stdout, cmd.Stderr = slave, slave, slave
		cmd.SysProcAttr.Setsid, cmd.SysProcAttr.Setctty = true, true
		// The terminal's device path, so the runtime can resize it (attach's
		// window-size messages) without holding it open.
		if spec.TTYFile != "" {
			_ = writeFileAtomic(spec.TTYFile, []byte(slave.Name()))
		}
		if err := cmd.Start(); err != nil {
			fail(err)
		}
		_ = slave.Close() // the child holds it now
		go func() { _, _ = io.Copy(stdout, master) }()
		if fifo != nil {
			go func() { _, _ = io.Copy(master, fifo) }()
		}
	} else {
		cmd.SysProcAttr.Setpgid = true
		cmd.Stdout, cmd.Stderr = stdout, stderr
		if fifo != nil {
			// A plain pipe between the fifo and the child: the child gets the
			// read end, which ends cleanly on close, while the fifo stays held
			// open. SIGUSR1 (stdinOnce) closes the write end, so the child reads
			// end-of-input.
			pr, pw, err := os.Pipe()
			if err != nil {
				fail(err)
			}
			cmd.Stdin, childStdin = pr, pr
			go func() { _, _ = io.Copy(pw, fifo) }()
			closeInput = func() { _ = pw.Close() }
		} else if devnull, err := os.Open(os.DevNull); err == nil {
			cmd.Stdin, childStdin = devnull, devnull
		}
		if err := cmd.Start(); err != nil {
			fail(err)
		}
	}
	if childStdin != nil {
		_ = childStdin.Close() // the child holds its own copy
	}

	// stdinOnce: the runtime signals when the one input stream has ended.
	// Installed before "ok", so a signal is never missed and never kills the
	// reaper (SIGUSR1's default disposition).
	sigUSR1 := make(chan os.Signal, 1)
	signal.Notify(sigUSR1, syscall.SIGUSR1)
	go func() {
		for range sigUSR1 {
			if closeInput != nil {
				closeInput()
			}
		}
	}()

	_ = writeFileAtomic(spec.PidFile, []byte(strconv.Itoa(cmd.Process.Pid)))
	fmt.Fprintf(report, "ok %d\n", cmd.Process.Pid)
	report.Close()

	_ = cmd.Wait()
	if master != nil {
		_ = master.Close() // ends the output copy
	}
	rec := exitRecord{Code: int32(cmd.ProcessState.ExitCode()), Finished: time.Now().UnixNano()}
	if ws, ok := cmd.ProcessState.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		rec.Code = 128 + int32(ws.Signal())
	}
	out, _ := json.Marshal(rec)
	_ = writeFileAtomic(spec.Exit, out)
}

// startReaper runs a container through the reaper and returns the reaper's
// process and the container's pid once it is running. The reaper opens the
// container's stdin, output and terminal itself, by the paths in the spec, so
// nothing of the container is held by this runtime.
func startReaper(dir string, spec reapSpec) (*os.Process, int, error) {
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
	if devnull, err := os.Open(os.DevNull); err == nil {
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
