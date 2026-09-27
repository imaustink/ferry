package main

// kubectl attach, and a container's stdin and terminal.
//
// A container's output used to go one way, into its log. For attach it has
// to go to whoever is attached as well, as it arrives, so each stream is read
// in chunks: the chunk goes to every attached client, and the lines in it go
// to the log in the kubelet's format. A pod that asks for `stdin: true` gets a
// pipe for its standard input that attach writes into -- closed after the
// first attach when it asked for `stdinOnce` -- and one that asks for `tty:
// true` runs on a pseudo-terminal, which attach reads, writes and resizes.

import (
	"context"
	"fmt"
	"io"
	"os"
	"sync"
	"time"

	"github.com/creack/pty"
	"k8s.io/client-go/tools/remotecommand"
)

// fanout copies a container's output to every attached client.
type fanout struct {
	mu   sync.Mutex
	next int
	subs map[int][2]io.Writer // stdout, stderr (nil for a terminal's)
}

func (f *fanout) subscribe(out, errOut io.Writer) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.subs == nil {
		f.subs = map[int][2]io.Writer{}
	}
	f.next++
	f.subs[f.next] = [2]io.Writer{out, errOut}
	return f.next
}

func (f *fanout) unsubscribe(id int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.subs, id)
}

func (f *fanout) write(stream int, p []byte) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for id, w := range f.subs {
		dst := w[stream]
		if dst == nil {
			dst = w[0]
		}
		if dst == nil {
			continue
		}
		if _, err := dst.Write(p); err != nil {
			delete(f.subs, id)
		}
	}
}

// pump reads one stream of a container: every chunk to the attached clients,
// every line to the log.
func (l *criLog) pump(stream string, r io.Reader, fan *fanout) {
	idx := 0
	if stream == "stderr" {
		idx = 1
	}
	buf := make([]byte, 32*1024)
	var line []byte
	for {
		n, err := r.Read(buf)
		if n > 0 {
			fan.write(idx, buf[:n])
			line = append(line, buf[:n]...)
			for {
				i := indexByte(line, '\n')
				if i < 0 {
					break
				}
				l.write(stream, "F", string(trimCR(line[:i])))
				line = line[i+1:]
			}
			if len(line) > 64*1024 {
				l.write(stream, "P", string(line))
				line = nil
			}
		}
		if err != nil {
			if len(line) > 0 {
				l.write(stream, "F", string(trimCR(line)))
			}
			return
		}
	}
}

func (l *criLog) write(stream, tag, text string) {
	if l == nil {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.f == nil {
		return
	}
	fmt.Fprintf(l.f, "%s %s %s %s\n", time.Now().Format(time.RFC3339Nano), stream, tag, text)
}

func indexByte(b []byte, c byte) int {
	for i, x := range b {
		if x == c {
			return i
		}
	}
	return -1
}

// A terminal ends its lines \r\n; the log wants them without the \r.
func trimCR(b []byte) []byte {
	if len(b) > 0 && b[len(b)-1] == '\r' {
		return b[:len(b)-1]
	}
	return b
}

// Attach connects a client to a running container's stdio.
func (s *streamRuntime) Attach(ctx context.Context, containerID string, in io.Reader, out, errOut io.WriteCloser, tty bool, resize <-chan remotecommand.TerminalSize) error {
	s.rt.mu.Lock()
	c, ok := s.rt.ctrs[containerID]
	s.rt.mu.Unlock()
	if !ok {
		return fmt.Errorf("container %q not found", containerID)
	}
	c.mu.Lock()
	done, stdin, term := c.done, c.stdin, c.pty
	c.mu.Unlock()
	if done == nil {
		return fmt.Errorf("container %s is not running", containerID)
	}

	var e io.Writer
	if errOut != nil {
		e = errOut
	}
	id := c.fan.subscribe(out, e)
	defer c.fan.unsubscribe(id)

	if term != nil && resize != nil {
		go func() {
			for size := range resize {
				_ = pty.Setsize(term, &pty.Winsize{Rows: size.Height, Cols: size.Width})
			}
		}()
	}
	inDone := make(chan struct{})
	if in != nil && stdin != nil {
		go func() {
			_, _ = io.Copy(stdin, in)
			// stdinOnce: the stream the first attach gave is the container's
			// whole input, so its end is the input's end.
			if c.stdinOnce {
				_ = stdin.Close()
			}
			close(inDone)
		}()
	}
	select {
	case <-done:
	case <-ctx.Done():
	case <-inDone:
		if c.stdinOnce {
			<-done
		}
	}
	return nil
}

// startStdio wires a container's standard streams before it starts: a
// terminal if it asked for one, otherwise pipes, and stdin only if it asked.
func (c *container) startStdio(start func() error, setTTY func()) (outputs []io.Reader, err error) {
	if c.tty {
		setTTY()
		term, err := startPTY(c)
		if err != nil {
			return nil, err
		}
		c.pty, c.stdin = term, term
		return []io.Reader{term}, nil
	}
	stdout, _ := c.cmd.StdoutPipe()
	stderr, _ := c.cmd.StderrPipe()
	if c.openStdin {
		w, err := c.cmd.StdinPipe()
		if err != nil {
			return nil, err
		}
		c.stdin = w
	}
	if err := start(); err != nil {
		return nil, err
	}
	return []io.Reader{stdout, stderr}, nil
}

func startPTY(c *container) (*os.File, error) {
	return pty.StartWithAttrs(c.cmd, nil, c.cmd.SysProcAttr)
}
