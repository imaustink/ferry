package main

// A container's output, from files rather than pipes.
//
// The container writes its stdout and stderr to two files in its state
// directory, opened append-only by the reaper. A file has no reader to lose, so
// the container keeps running and keeps writing when the runtime is gone. The
// runtime follows both files: every chunk to the attached clients, every line
// to the kubelet's log in the CRI format. How far it has read is saved with the
// container, at the last line boundary, so a restarted runtime carries on from
// there -- what the container wrote while it was down reaches the log late but
// whole, not twice and not never.

import (
	"io"
	"log"
	"os"
	"time"
)

var streamNames = [2]string{"stdout", "stderr"}

// follow tails a container's two output files until it has exited and both
// are drained.
func (r *runtimeSvc) follow(c *container) {
	c.mu.Lock()
	paths := [2]string{c.stdoutPath, c.stderrPath}
	offs := c.logOffsets
	done := c.done
	c.mu.Unlock()

	defer c.clog.close()
	var files [2]*os.File
	for i, p := range paths {
		// Read-write, for punching out what has been read (below).
		f, err := os.OpenFile(p, os.O_RDWR, 0)
		if err != nil {
			log.Printf("container %s: following %s: %v", c.id, p, err)
			return
		}
		defer f.Close()
		if _, err := f.Seek(offs[i], io.SeekStart); err != nil {
			log.Printf("container %s: seeking %s: %v", c.id, p, err)
			return
		}
		files[i] = f
	}

	// Once in the kubelet's log, the output files' bytes are only disk used
	// twice -- and the kubelet rotates its log, where these would grow for as
	// long as the container runs. So what has been read is punched out
	// (F_PUNCHHOLE): the blocks are freed, while the file keeps its size and
	// the offsets above stay true, and the container's appends are untouched.
	var punched [2]int64
	punch := func(i int) {
		upto := offs[i] &^ (64*1024 - 1) // whole 64 KiB blocks, below what is read
		if upto-punched[i] < 1<<20 {
			return
		}
		if err := punchHole(files[i].Fd(), punched[i], upto-punched[i]); err == nil {
			punched[i] = upto
		}
	}
	var partial [2][]byte
	buf := make([]byte, 32*1024)
	lastSave := time.Now()
	exited := false
	for {
		read := false
		for i, f := range files {
			n, _ := f.Read(buf)
			if n == 0 {
				continue
			}
			read = true
			c.fan.write(i, buf[:n])
			line := append(partial[i], buf[:n]...)
			for {
				j := indexByte(line, '\n')
				if j < 0 {
					break
				}
				c.clog.write(streamNames[i], "F", string(trimCR(line[:j])))
				offs[i] += int64(j + 1)
				line = line[j+1:]
			}
			if len(line) > 64*1024 {
				c.clog.write(streamNames[i], "P", string(line))
				offs[i] += int64(len(line))
				line = nil
			}
			partial[i] = append([]byte(nil), line...)
		}
		if read && time.Since(lastSave) > time.Second {
			r.saveOffsets(c, offs)
			lastSave = time.Now()
			// After the save: a hole is only ever behind an offset on disk.
			punch(0)
			punch(1)
		}
		if read {
			continue
		}
		if exited {
			// Drained after the exit: what is left without a newline is still a
			// line the container wrote.
			for i := range partial {
				if len(partial[i]) > 0 {
					c.clog.write(streamNames[i], "F", string(trimCR(partial[i])))
					offs[i] += int64(len(partial[i]))
				}
			}
			r.saveOffsets(c, offs)
			return
		}
		select {
		case <-done:
			exited = true // one more pass, for what arrived just before the exit
		case <-time.After(50 * time.Millisecond):
		}
	}
}

func (r *runtimeSvc) saveOffsets(c *container, offs [2]int64) {
	c.mu.Lock()
	c.logOffsets = offs
	c.mu.Unlock()
	r.saveContainer(c)
}
