package main

// Running a CNI plugin inside a pod.
//
// ferry-cri owns the virtual machines, so it is the only process that can put
// anything inside one. It already accepts exec requests on a unix socket --
// that is how `kubectl exec` works here, with ferry-streamer speaking SPDY on
// one side and this framing on the other:
//
//	[1 byte channel][4 bytes big-endian length][payload]
//
// A CNI plugin needs nothing further. It is a process that reads stdin, writes
// stdout, and looks at its environment, and CNI_NETNS is the pod's own root
// netns because the VM boundary *is* the netns boundary.

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
)

type channel byte

const (
	chStdin  channel = 0
	chStdout channel = 1
	chStderr channel = 2
	chExit   channel = 3
)

const maxFrame = 1 << 20

// execRequest is ferry-cri's exec header. `env` and `caps` are what a CNI
// plugin needs beyond what `kubectl exec` does: the verb travels in the
// environment, and programming a kernel's netfilter tables takes NET_ADMIN --
// which an ordinary pod does not ask for and should not be given. Granting it
// to a binary ferry ships and runs keeps the privilege off the workload.
type execRequest struct {
	Op          string   `json:"op"`
	ContainerID string   `json:"containerID"`
	Cmd         []string `json:"cmd"`
	Env         []string `json:"env,omitempty"`
	Caps        []string `json:"caps,omitempty"`
	Stdin       bool     `json:"stdin"`
	TTY         bool     `json:"tty"`
}

func (d *dispatcher) execInPod(ctx context.Context, pluginPath string, stdinData []byte, environ []string) ([]byte, error) {
	if d.execSocket == "" || d.execTarget == "" {
		return nil, fmt.Errorf("%w: no exec socket or target container for %s", errPodGone, pluginPath)
	}

	conn, err := net.Dial("unix", d.execSocket)
	if err != nil {
		return nil, fmt.Errorf("%w: reach ferry-cri at %s: %v", errPodGone, d.execSocket, err)
	}
	defer conn.Close()
	go func() { <-ctx.Done(); conn.Close() }()

	request := execRequest{
		Op:          "exec",
		ContainerID: d.execTarget,
		Cmd:         []string{pluginPath},
		Env:         guestEnviron(environ, d.guestPath),
		Caps:        []string{"NET_ADMIN"},
		Stdin:       true,
	}
	header, err := json.Marshal(request)
	if err != nil {
		return nil, err
	}
	if _, err := conn.Write(append(header, '\n')); err != nil {
		return nil, fmt.Errorf("%w: %v", errPodGone, err)
	}

	// The configuration, then end-of-input. A plugin reads stdin to EOF, so
	// without the empty frame it would wait forever.
	if err := writeFrame(conn, chStdin, stdinData); err != nil {
		return nil, err
	}
	if err := writeFrame(conn, chStdin, nil); err != nil {
		return nil, err
	}

	var stdout, stderr []byte
	for {
		c, payload, err := readFrame(conn)
		if err != nil {
			if errors.Is(err, io.EOF) {
				// No exit frame: ferry-cri went away mid-call.
				return nil, fmt.Errorf("%w: %s ended without an exit status", errPodGone, pluginPath)
			}
			return nil, err
		}
		switch c {
		case chStdout:
			stdout = append(stdout, payload...)
		case chStderr:
			stderr = append(stderr, payload...)
		case chExit:
			code := 0
			if len(payload) > 0 {
				code = int(payload[0])
			}
			if len(stderr) > 0 {
				fmt.Fprintf(os.Stderr, "%s: %s", base(pluginPath), stderr)
			}
			if code != 0 {
				// A plugin reports failure as a JSON error object on stdout,
				// not on stderr -- so the useful half of the message is in the
				// stream a shell would have thrown away.
				detail := strings.TrimSpace(string(stdout))
				if detail == "" {
					detail = strings.TrimSpace(string(stderr))
				}
				return nil, fmt.Errorf("%s in the pod exited %d: %s",
					base(pluginPath), code, detail)
			}
			return stdout, nil
		}
	}
}

// guestEnviron keeps the CNI variables and drops the rest.
//
// libcni builds a plugin's environment by appending to this process's own, and
// this process runs on a Mac: its PATH, HOME and TMPDIR name directories that
// do not exist in the pod and would be actively misleading there. What the
// plugin does need is a PATH that finds nft, because portmap's nftables backend
// shells out to it -- and ferry already ships nft into every pod.
func guestEnviron(environ []string, guestPath string) []string {
	out := []string{
		"PATH=" + strings.Join([]string{guestPath, "/.ferry", "/usr/sbin", "/usr/bin", "/sbin", "/bin"}, ":"),
		// CNI's own escape hatch, and ferry is the case it exists for.
		//
		// After a successful ADD, skel checks that the plugin did not end up in
		// the namespace named by CNI_NETNS -- on Linux that means a plugin
		// leaked into the container, which is a bug. Here it is the design: the
		// pod is a virtual machine, its root netns is the sandbox, and the
		// plugin runs inside it. The work succeeds and only the check fails, so
		// without this a correctly programmed pod reports error 8.
		"CNI_NETNS_OVERRIDE=true",
	}
	for _, entry := range environ {
		if !strings.HasPrefix(entry, "CNI_") {
			continue
		}
		// CNI_PATH names the directories a plugin would delegate through, and
		// the ones libcni filled in are on the Mac. Inside the pod the only
		// plugins that exist are the ones shared in.
		if strings.HasPrefix(entry, "CNI_PATH=") {
			entry = "CNI_PATH=" + guestPath
		}
		out = append(out, entry)
	}
	return out
}

func base(path string) string {
	if i := strings.LastIndex(path, "/"); i >= 0 {
		return path[i+1:]
	}
	return path
}

func writeFrame(w io.Writer, c channel, payload []byte) error {
	header := make([]byte, 5)
	header[0] = byte(c)
	binary.BigEndian.PutUint32(header[1:], uint32(len(payload)))
	if _, err := w.Write(header); err != nil {
		return err
	}
	if len(payload) == 0 {
		return nil
	}
	_, err := w.Write(payload)
	return err
}

func readFrame(r io.Reader) (channel, []byte, error) {
	header := make([]byte, 5)
	if _, err := io.ReadFull(r, header); err != nil {
		return 0, nil, err
	}
	length := binary.BigEndian.Uint32(header[1:])
	if length > maxFrame {
		return 0, nil, fmt.Errorf("frame of %d bytes exceeds the %d byte limit", length, maxFrame)
	}
	if length == 0 {
		return channel(header[0]), nil, nil
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(r, payload); err != nil {
		return 0, nil, err
	}
	return channel(header[0]), payload, nil
}
