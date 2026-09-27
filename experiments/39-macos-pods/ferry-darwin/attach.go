package main

// kubectl attach, and a container's stdin and terminal.
//
// A container's output goes to files the reaper writes and the runtime follows
// (tail.go); attach subscribes to that follow through the fanout here, so a
// client sees output as it arrives without the runtime owning the container's
// streams. Input goes the other way: attach writes the client's bytes into the
// container's stdin fifo, which the reaper holds and copies to the child. A
// `tty: true` container's terminal is the reaper's too; attach resizes it by
// opening its device, and ends stdinOnce input by signalling the reaper.

import (
	"context"
	"fmt"
	"io"
	"os"
	"sync"
	"syscall"
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
	done, stdin, ttyPath, reaperPid := c.done, c.stdin, c.ttyPath, c.reaperPid
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

	// Resize the terminal the reaper holds by opening its device, since the
	// runtime no longer keeps the terminal itself.
	if c.tty && ttyPath != "" && resize != nil {
		if term, err := os.OpenFile(ttyPath, os.O_RDWR, 0); err == nil {
			defer term.Close()
			go func() {
				for size := range resize {
					_ = pty.Setsize(term, &pty.Winsize{Rows: size.Height, Cols: size.Width})
				}
			}()
		}
	}
	inDone := make(chan struct{})
	if in != nil && stdin != nil {
		go func() {
			_, _ = io.Copy(stdin, in)
			// stdinOnce: the stream the first attach gave is the container's
			// whole input, so its end is the input's end. The stdin fifo is held
			// open by the reaper, so the runtime cannot end it by closing its own
			// handle; it signals the reaper to close the child's stdin instead.
			if c.stdinOnce && reaperPid > 0 {
				_ = syscall.Kill(reaperPid, syscall.SIGUSR1)
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
