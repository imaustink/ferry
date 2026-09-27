package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
)

// macBuilder drives `macvm build <golden>` as a coprocess: one exec request
// per line on its stdin, agent.swift's own frames (type 1 stdout, 2 stderr, 3
// exit, 4 error) relayed back verbatim on fd 3. See macvm.swift's "build" case
// for the other half of this protocol, and FINDINGS.md for why it exists
// instead of a shared directory.
type macBuilder struct {
	cmd   *exec.Cmd
	stdin io.WriteCloser
	ctrl  *bufio.Reader
	ctrlR *os.File
}

type request struct {
	Argv []string          `json:"argv"`
	Env  map[string]string `json:"env,omitempty"`
	Cwd  string            `json:"cwd,omitempty"`
}

func startMacBuilder(macvmPath, golden string) (*macBuilder, error) {
	ctrlR, ctrlW, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(macvmPath, "build", golden)
	cmd.Stderr = os.Stderr // macvm's own timestamped log lines: progress, not protocol
	cmd.ExtraFiles = []*os.File{ctrlW}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		ctrlR.Close()
		ctrlW.Close()
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		ctrlR.Close()
		ctrlW.Close()
		return nil, err
	}
	ctrlW.Close() // the child holds its own copy (fd 3); this one is ours to close
	return &macBuilder{cmd: cmd, stdin: stdin, ctrl: bufio.NewReader(ctrlR), ctrlR: ctrlR}, nil
}

// run sends one exec request and blocks for its outcome: every stdout frame
// concatenated, and the exit code agent.swift reported. A type-4 frame (a
// malformed request, or the agent refusing to connect) surfaces as an error
// instead of a code, since no process ever ran.
func (b *macBuilder) run(argv []string, env map[string]string, cwd string) ([]byte, int32, error) {
	line, err := json.Marshal(request{Argv: argv, Env: env, Cwd: cwd})
	if err != nil {
		return nil, 0, err
	}
	line = append(line, '\n')
	if _, err := b.stdin.Write(line); err != nil {
		return nil, 0, fmt.Errorf("writing to builder: %w", err)
	}

	var stdout bytes.Buffer
	for {
		header := make([]byte, 5)
		if _, err := io.ReadFull(b.ctrl, header); err != nil {
			return stdout.Bytes(), -1, fmt.Errorf("builder control channel: %w", err)
		}
		length := binary.BigEndian.Uint32(header[1:])
		payload := make([]byte, length)
		if length > 0 {
			if _, err := io.ReadFull(b.ctrl, payload); err != nil {
				return stdout.Bytes(), -1, fmt.Errorf("builder control channel: %w", err)
			}
		}
		switch header[0] {
		case 1:
			stdout.Write(payload)
		case 2:
			os.Stderr.Write(payload)
		case 3:
			return stdout.Bytes(), int32(binary.BigEndian.Uint32(payload)), nil
		case 4:
			return stdout.Bytes(), -1, fmt.Errorf("builder: %s", payload)
		}
	}
}

// close ends the stdin stream, which is the builder's signal to shut the
// guest down and exit; then waits for it to actually do so.
func (b *macBuilder) close() error {
	b.stdin.Close()
	err := b.cmd.Wait()
	b.ctrlR.Close()
	return err
}
