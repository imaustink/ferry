package main

// kubectl exec and port-forward, for pods on a macOS node.
//
// CRI does not carry these over gRPC: the runtime answers Exec and PortForward
// with a URL, and the kubelet proxies the client's upgraded connection to it.
// Kubernetes ships the server that speaks the far side of that
// (k8s.io/kubelet/pkg/cri/streaming), the one ferry-streamer runs for the
// Mac's pod VMs. Here the runtime is Go, so it is embedded, and this is the
// half that reaches into a pod:
//
//	exec          a process in the container's root, as its uid, with its
//	              environment and the shim -- another process of the pod, the
//	              way a Linux runtime's exec joins the container's namespaces.
//	              With -t it gets a pseudo-terminal.
//	port-forward  a connection from the node to the pod's own address.
//
// Attach is in attach.go.

import (
	"context"
	"fmt"
	"io"
	"log"
	"net"
	"net/url"
	"os/exec"
	"strconv"
	"syscall"
	"time"

	"github.com/creack/pty"
	"k8s.io/client-go/tools/remotecommand"
	runtimeapi "k8s.io/cri-api/pkg/apis/runtime/v1"
	"k8s.io/kubelet/pkg/cri/streaming"
)

type streamRuntime struct{ rt *runtimeSvc }

func newStreamingServer(rt *runtimeSvc, listen string) (streaming.Server, error) {
	base, err := url.Parse("http://" + listen + "/")
	if err != nil {
		return nil, err
	}
	return streaming.NewServer(streaming.Config{
		Addr:                            listen,
		BaseURL:                         base,
		StreamIdleTimeout:               4 * time.Hour,
		StreamCreationTimeout:           streaming.DefaultConfig.StreamCreationTimeout,
		SupportedRemoteCommandProtocols: streaming.DefaultConfig.SupportedRemoteCommandProtocols,
		SupportedPortForwardProtocols:   streaming.DefaultConfig.SupportedPortForwardProtocols,
	}, &streamRuntime{rt: rt})
}

// execError carries a non-zero exit status in the shape the streaming server
// wants -- the whole of k8s.io/utils/exec.ExitError, as ferry-streamer found:
// with ExitStatus alone every failure is reported as 1.
type execError struct{ code int }

func (e execError) Error() string   { return fmt.Sprintf("command terminated with exit code %d", e.code) }
func (e execError) ExitStatus() int { return e.code }
func (e execError) Exited() bool    { return true }
func (e execError) String() string  { return e.Error() }

// command builds a process that joins a container: its root, its uid, its
// environment and working directory, argv[0] resolved inside the root.
func (s *streamRuntime) command(containerID string, argv []string) (*exec.Cmd, *syscall.SysProcAttr, error) {
	s.rt.mu.Lock()
	c, ok := s.rt.ctrs[containerID]
	var sb *sandbox
	if ok {
		sb = s.rt.sboxes[c.sandboxID]
	}
	s.rt.mu.Unlock()
	if !ok || sb == nil {
		return nil, nil, fmt.Errorf("container %q not found", containerID)
	}
	if len(argv) == 0 {
		return nil, nil, fmt.Errorf("no command")
	}
	probe := &container{root: c.root, argv: argv}
	path, err := probe.resolve()
	if err != nil {
		return nil, nil, err
	}
	cmd := &exec.Cmd{Path: path, Args: argv, Env: c.env, Dir: c.workdir}
	attrs := &syscall.SysProcAttr{
		Chroot:     c.root,
		Credential: &syscall.Credential{Uid: uint32(sb.addr.uid), Gid: uint32(sb.addr.uid)},
	}
	return cmd, attrs, nil
}

func exitError(cmd *exec.Cmd, err error) error {
	if cmd.ProcessState == nil {
		return err
	}
	code := cmd.ProcessState.ExitCode()
	if ws, ok := cmd.ProcessState.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		code = 128 + int(ws.Signal())
	}
	if code == 0 {
		return nil
	}
	return execError{code: code}
}

func (s *streamRuntime) Exec(ctx context.Context, containerID string, argv []string, in io.Reader, out, errOut io.WriteCloser, tty bool, resize <-chan remotecommand.TerminalSize) error {
	cmd, attrs, err := s.command(containerID, argv)
	if err != nil {
		return err
	}
	log.Printf("exec %s: %v (tty %v)", containerID, argv, tty)
	if !tty {
		attrs.Setpgid = true
		cmd.SysProcAttr = attrs
		cmd.Stdin, cmd.Stdout = in, out
		if errOut != nil {
			cmd.Stderr = errOut
		}
		if err := cmd.Start(); err != nil {
			return err
		}
		go func() {
			<-ctx.Done()
			if cmd.ProcessState == nil && cmd.Process != nil {
				_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
			}
		}()
		return exitError(cmd, cmd.Wait())
	}

	// A terminal: the pty package opens the pair here and makes the pty the
	// child's controlling terminal, on top of the chroot and the uid.
	attrs.Setsid, attrs.Setctty = true, true
	f, err := pty.StartWithAttrs(cmd, nil, attrs)
	if err != nil {
		return err
	}
	defer f.Close()
	go func() {
		for size := range resize {
			_ = pty.Setsize(f, &pty.Winsize{Rows: size.Height, Cols: size.Width})
		}
	}()
	if in != nil {
		go func() { _, _ = io.Copy(f, in) }()
	}
	_, _ = io.Copy(out, f) // ends when the process closes its side
	return exitError(cmd, cmd.Wait())
}

// PortForward dials the pod's own address, from the node's (see localAddr).
func (s *streamRuntime) PortForward(ctx context.Context, podSandboxID string, port int32, stream io.ReadWriteCloser) error {
	defer stream.Close()
	s.rt.mu.Lock()
	sb, ok := s.rt.sboxes[podSandboxID]
	s.rt.mu.Unlock()
	if !ok {
		return fmt.Errorf("sandbox %q not found", podSandboxID)
	}
	d := net.Dialer{Timeout: 5 * time.Second, LocalAddr: &net.TCPAddr{IP: s.rt.node.localAddr()}}
	conn, err := d.Dial("tcp", net.JoinHostPort(sb.addr.ip, strconv.Itoa(int(port))))
	if err != nil {
		return err
	}
	defer conn.Close()
	log.Printf("port-forward %s: %s:%d", podSandboxID, sb.addr.ip, port)
	done := make(chan struct{}, 2)
	go func() { _, _ = io.Copy(conn, stream); done <- struct{}{} }()
	go func() { _, _ = io.Copy(stream, conn); done <- struct{}{} }()
	select {
	case <-done:
	case <-ctx.Done():
	}
	return nil
}

// ExecSync: an exec probe, or `crictl exec --sync`. Output is collected and
// the command killed at the timeout.
func (r *runtimeSvc) ExecSync(ctx context.Context, req *runtimeapi.ExecSyncRequest) (*runtimeapi.ExecSyncResponse, error) {
	s := &streamRuntime{rt: r}
	cmd, attrs, err := s.command(req.ContainerId, req.Cmd)
	if err != nil {
		return nil, err
	}
	attrs.Setpgid = true
	cmd.SysProcAttr = attrs
	var stdout, stderr limitedBuffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	timeout := time.Duration(req.Timeout) * time.Second
	if timeout <= 0 {
		timeout = time.Hour
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case <-done:
	case <-time.After(timeout):
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		<-done
		return nil, fmt.Errorf("command %v timed out after %s", req.Cmd, timeout)
	}
	code := int32(0)
	if e, ok := exitError(cmd, nil).(execError); ok {
		code = int32(e.code)
	}
	return &runtimeapi.ExecSyncResponse{Stdout: stdout.b, Stderr: stderr.b, ExitCode: code}, nil
}

// limitedBuffer keeps the first 16 MiB, as the CRI asks runtimes to bound
// ExecSync output.
type limitedBuffer struct{ b []byte }

func (l *limitedBuffer) Write(p []byte) (int, error) {
	if room := 16<<20 - len(l.b); room > 0 {
		if len(p) < room {
			room = len(p)
		}
		l.b = append(l.b, p[:room]...)
	}
	return len(p), nil
}

func (r *runtimeSvc) Exec(_ context.Context, req *runtimeapi.ExecRequest) (*runtimeapi.ExecResponse, error) {
	if r.streaming == nil {
		return nil, fmt.Errorf("streaming is off")
	}
	return r.streaming.GetExec(req)
}

func (r *runtimeSvc) PortForward(_ context.Context, req *runtimeapi.PortForwardRequest) (*runtimeapi.PortForwardResponse, error) {
	if r.streaming == nil {
		return nil, fmt.Errorf("streaming is off")
	}
	return r.streaming.GetPortForward(req)
}

func (r *runtimeSvc) Attach(_ context.Context, req *runtimeapi.AttachRequest) (*runtimeapi.AttachResponse, error) {
	if r.streaming == nil {
		return nil, fmt.Errorf("streaming is off")
	}
	return r.streaming.GetAttach(req)
}
