// ferry-streamer serves kubectl exec, attach and port-forward.
//
// CRI does not carry these over gRPC. The runtime returns a URL and the kubelet
// proxies the client's upgraded connection to it, speaking SPDY/3.1:
//
//	Upgrade: SPDY/3.1
//	X-Stream-Protocol-Version: v5.channel.k8s.io ... channel.k8s.io
//
// SPDY/3.1 is a dead protocol with its own zlib-dictionary header compression,
// and Kubernetes already ships a correct server for it. So the streaming half
// lives here in Go, using that library, and the half that can actually reach
// into a pod's virtual machine stays in ferry-cri. The two are joined by a
// framed unix socket.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"time"

	"k8s.io/apimachinery/pkg/util/runtime"
	runtimeapi "k8s.io/cri-api/pkg/apis/runtime/v1"
	"k8s.io/client-go/tools/remotecommand"
	"k8s.io/kubelet/pkg/cri/streaming"
)

func main() {
	listen := flag.String("listen", "127.0.0.1:10350", "address to serve streaming requests on")
	execSocket := flag.String("exec-socket", "/tmp/ferry-exec.sock", "ferry-cri's exec socket")
	control := flag.String("control", "/tmp/ferry-streamer.sock", "socket ferry-cri asks for URLs on")
	flag.Parse()

	baseURL, err := url.Parse("http://" + *listen + "/")
	if err != nil {
		fmt.Fprintf(os.Stderr, "bad listen address: %v\n", err)
		os.Exit(2)
	}

	server, err := streaming.NewServer(streaming.Config{
		Addr:                            *listen,
		BaseURL:                         baseURL,
		StreamIdleTimeout:               4 * time.Hour,
		StreamCreationTimeout:           streaming.DefaultConfig.StreamCreationTimeout,
		SupportedRemoteCommandProtocols: streaming.DefaultConfig.SupportedRemoteCommandProtocols,
		SupportedPortForwardProtocols:   streaming.DefaultConfig.SupportedPortForwardProtocols,
	}, &podRuntime{execSocket: *execSocket})
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to create streaming server: %v\n", err)
		os.Exit(1)
	}

	// ferry-cri mints URLs through here: the token in the URL is issued by the
	// streaming server's request cache, so only it can hand them out.
	_ = os.Remove(*control)
	controlListener, err := net.Listen("unix", *control)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to listen on %s: %v\n", *control, err)
		os.Exit(1)
	}
	go func() {
		mux := http.NewServeMux()
		mux.HandleFunc("/exec", func(w http.ResponseWriter, r *http.Request) {
			var req runtimeapi.ExecRequest
			if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
			resp, err := server.GetExec(&req)
			if err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			json.NewEncoder(w).Encode(map[string]string{"url": resp.Url})
		})
		mux.HandleFunc("/attach", func(w http.ResponseWriter, r *http.Request) {
			var req runtimeapi.AttachRequest
			if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
			resp, err := server.GetAttach(&req)
			if err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			json.NewEncoder(w).Encode(map[string]string{"url": resp.Url})
		})
		runtime.HandleError(http.Serve(controlListener, mux))
	}()

	fmt.Printf("==> ferry-streamer\n    streaming  http://%s/\n    control    unix://%s\n    exec via   unix://%s\n    serving\n",
		*listen, *control, *execSocket)
	if err := server.Start(true); err != nil {
		fmt.Fprintf(os.Stderr, "streaming server stopped: %v\n", err)
		os.Exit(1)
	}
}

// podRuntime satisfies streaming.Runtime by handing each request to ferry-cri
// over the exec socket. It knows nothing about virtual machines.
type podRuntime struct {
	execSocket string
}

type execHeader struct {
	ContainerID string   `json:"containerID"`
	Cmd         []string `json:"cmd"`
	TTY         bool     `json:"tty"`
	Stdin       bool     `json:"stdin"`
}

func (p *podRuntime) Exec(ctx context.Context, containerID string, cmd []string, in io.Reader, out, errOut io.WriteCloser, tty bool, resize <-chan remotecommand.TerminalSize) error {
	return p.stream(ctx, execHeader{ContainerID: containerID, Cmd: cmd, TTY: tty, Stdin: in != nil}, in, out, errOut, resize)
}

// Attach reuses the exec path with no command: ferry-cri interprets an empty
// command as attaching to the container's own process.
func (p *podRuntime) Attach(ctx context.Context, containerID string, in io.Reader, out, errOut io.WriteCloser, tty bool, resize <-chan remotecommand.TerminalSize) error {
	return p.stream(ctx, execHeader{ContainerID: containerID, TTY: tty, Stdin: in != nil}, in, out, errOut, resize)
}

func (p *podRuntime) PortForward(ctx context.Context, sandboxID string, port int32, stream io.ReadWriteCloser) error {
	return fmt.Errorf("port forwarding is not implemented yet")
}

func (p *podRuntime) stream(ctx context.Context, header execHeader, in io.Reader, out, errOut io.WriteCloser, resize <-chan remotecommand.TerminalSize) error {
	conn, err := net.Dial("unix", p.execSocket)
	if err != nil {
		return fmt.Errorf("reach ferry-cri: %w", err)
	}
	defer conn.Close()

	encoded, err := json.Marshal(header)
	if err != nil {
		return err
	}
	if _, err := conn.Write(append(encoded, '\n')); err != nil {
		return err
	}

	if in != nil {
		go func() {
			buf := make([]byte, 32*1024)
			for {
				n, err := in.Read(buf)
				if n > 0 {
					if writeFrame(conn, chStdin, buf[:n]) != nil {
						return
					}
				}
				if err != nil {
					// Closing stdin is meaningful: it is how a command reading
					// from a pipe learns there is no more input.
					_ = writeFrame(conn, chStdin, nil)
					return
				}
			}
		}()
	}

	if resize != nil {
		go func() {
			for size := range resize {
				payload, err := json.Marshal(map[string]uint16{"width": size.Width, "height": size.Height})
				if err != nil || writeFrame(conn, chResize, payload) != nil {
					return
				}
			}
		}()
	}

	go func() { <-ctx.Done(); conn.Close() }()

	for {
		c, payload, err := readFrame(conn)
		if err != nil {
			if err == io.EOF {
				return nil
			}
			return err
		}
		switch c {
		case chStdout:
			if out != nil {
				if _, err := out.Write(payload); err != nil {
					return err
				}
			}
		case chStderr:
			if errOut != nil {
				if _, err := errOut.Write(payload); err != nil {
					return err
				}
			}
		case chExit:
			if len(payload) > 0 && payload[0] != 0 {
				// The client shows this as the command's exit status.
				return execError{code: int(payload[0])}
			}
			return nil
		}
	}
}

// execError carries a non-zero exit status back in the shape the streaming
// server expects, so `kubectl exec` exits with the same code the command did.
// The full k8s.io/utils/exec.ExitError interface is required -- with only
// ExitStatus the server cannot tell this apart from a transport failure and
// reports 1 for everything.
type execError struct{ code int }

func (e execError) Error() string   { return fmt.Sprintf("command terminated with exit code %d", e.code) }
func (e execError) ExitStatus() int { return e.code }
func (e execError) Exited() bool    { return true }
func (e execError) String() string  { return e.Error() }
