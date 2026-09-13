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
	"strconv"
	"time"

	"k8s.io/apimachinery/pkg/util/runtime"
	runtimeapi "k8s.io/cri-api/pkg/apis/runtime/v1"
	"k8s.io/client-go/tools/remotecommand"
	"k8s.io/kubelet/pkg/cri/streaming"
)

func main() {
	listen := flag.String("listen", "127.0.0.1:10350", "address to serve streaming requests on")
	kubeconfig := flag.String("kubeconfig", "", "kubeconfig used to read pod specs (optional)")
	execSocket := flag.String("exec-socket", "/tmp/ferry-exec.sock", "ferry-cri's exec socket")
	control := flag.String("control", "/tmp/ferry-streamer.sock", "socket ferry-cri asks for URLs on")
	nodeName := flag.String("node-name", "", "this node, for advertising its switch endpoint")
	relayEndpoint := flag.String("relay-endpoint", "", "host:port this node's pod switch listens on")
	peersFile := flag.String("peers-file", "", "file to keep the other nodes' endpoints in")
	gpudSocket := flag.String("gpud-socket", "", "ferry-gpud's control socket, to keep ferry.dev/gpu current")
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
	controlMux := http.NewServeMux()
	go func() {
		mux := controlMux
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
		mux.HandleFunc("/portforward", func(w http.ResponseWriter, r *http.Request) {
			var req runtimeapi.PortForwardRequest
			if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
			resp, err := server.GetPortForward(&req)
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

	// ferry-cri needs to know how many containers a pod has before it boots the
	// VM, because this hypervisor cannot add one afterwards. CRI never says, so
	// the answer comes from the pod spec.
	var pods *podLookup
	if *kubeconfig != "" && *nodeName != "" && *relayEndpoint != "" && *peersFile != "" {
		if publisher, err := newPeerPublisher(*kubeconfig, *nodeName, *relayEndpoint, *peersFile); err != nil {
			fmt.Fprintf(os.Stderr, "peers: %v\n", err)
		} else {
			go publisher.run(context.Background())
		}
	}

	// ferry.dev/gpu is advertised at 'ferry up', but a Node object can be
	// recreated and ferry-gpud can die; either way the node would be lying about
	// what it can run. This keeps the resource matching the daemon.
	if *kubeconfig != "" && *nodeName != "" && *gpudSocket != "" {
		if publisher, err := newGPUPublisher(*kubeconfig, *nodeName, *gpudSocket); err != nil {
			fmt.Fprintf(os.Stderr, "gpu: %v\n", err)
		} else {
			go publisher.run(context.Background())
		}
	}

	if *kubeconfig != "" {
		pods, err = newPodLookup(*kubeconfig)
		if err != nil {
			fmt.Fprintf(os.Stderr, "warning: pod lookup unavailable, sidecars will not work: %v\n", err)
		}
	}
	go servePodLookup(controlMux, pods)

	stop := make(chan struct{})
	defer close(stop)
	serveServices(controlMux, newServiceWatch(pods, stop))

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
	Op          string   `json:"op,omitempty"`
	ContainerID string   `json:"containerID"`
	Cmd         []string `json:"cmd"`
	TTY         bool     `json:"tty"`
	Stdin       bool     `json:"stdin"`
}

func (p *podRuntime) Exec(ctx context.Context, containerID string, cmd []string, in io.Reader, out, errOut io.WriteCloser, tty bool, resize <-chan remotecommand.TerminalSize) error {
	return p.stream(ctx, execHeader{Op: "exec", ContainerID: containerID, Cmd: cmd, TTY: tty, Stdin: in != nil}, in, out, errOut, resize)
}

// Attach reconnects to the container's own process rather than starting a new
// one. ferry-cri subscribes the connection to the output already flowing
// through that container's log writer.
func (p *podRuntime) Attach(ctx context.Context, containerID string, in io.Reader, out, errOut io.WriteCloser, tty bool, resize <-chan remotecommand.TerminalSize) error {
	return p.stream(ctx, execHeader{Op: "attach", ContainerID: containerID, TTY: tty, Stdin: in != nil}, in, out, errOut, resize)
}

// PortForward is unusually simple here because pod IPs are routable from the
// Mac: there is no namespace to enter and nothing to proxy through ferry-cri.
// It only needs the pod's address, then it dials and splices.
func (p *podRuntime) PortForward(ctx context.Context, sandboxID string, port int32, stream io.ReadWriteCloser) error {
	address, err := p.podAddress(sandboxID)
	if err != nil {
		return err
	}
	target := net.JoinHostPort(address, strconv.Itoa(int(port)))

	dialer := net.Dialer{Timeout: 10 * time.Second}
	upstream, err := dialer.DialContext(ctx, "tcp", target)
	if err != nil {
		return fmt.Errorf("reach %s: %w", target, err)
	}
	defer upstream.Close()

	done := make(chan error, 2)
	go func() { _, err := io.Copy(upstream, stream); done <- err }()
	go func() { _, err := io.Copy(stream, upstream); done <- err }()

	// One direction closing ends the forward, which is what kubectl expects
	// when either side hangs up.
	select {
	case err := <-done:
		return err
	case <-ctx.Done():
		return ctx.Err()
	}
}

// podAddress asks ferry-cri which address a sandbox has. Only ferry-cri knows,
// since it allocated it.
func (p *podRuntime) podAddress(sandboxID string) (string, error) {
	conn, err := net.Dial("unix", p.execSocket)
	if err != nil {
		return "", fmt.Errorf("reach ferry-cri: %w", err)
	}
	defer conn.Close()

	request, err := json.Marshal(map[string]string{"op": "podip", "sandboxID": sandboxID})
	if err != nil {
		return "", err
	}
	if _, err := conn.Write(append(request, '\n')); err != nil {
		return "", err
	}

	var reply struct {
		IP string `json:"ip"`
	}
	if err := json.NewDecoder(conn).Decode(&reply); err != nil {
		return "", fmt.Errorf("read pod address: %w", err)
	}
	if reply.IP == "" {
		return "", fmt.Errorf("sandbox %s has no address", sandboxID)
	}
	return reply.IP, nil
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
