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

// builderConfig says where the macOS builder VM comes from: golden is a VM
// bundle (what FERRY_MAC_IMAGE points ferry-machined at, for machines), and
// macvmPath is the ferry-macvm binary `ferry build` compiles. Either being
// empty means "no builder available" -- fine for a Dockerfile with no RUN,
// an error for one that has it.
type builderConfig struct {
	golden    string
	macvmPath string
}

// guestRoot is the one directory a build ever touches inside the builder VM.
// COPY lands here (pushed as a tar over the exec channel -- see pushCopy),
// RUN's cwd defaults to it, and the whole tree is read back once, at the end
// (pullRoot), to become the image's single layer.
const guestRoot = "/private/var/ferry/build"

// macBuilder drives `ferry-macvm build <golden>` as a coprocess: one exec
// request per line on its stdin, its relayed response frames (agent.swift's
// own type 1 stdout, 2 stderr, 3 exit, 4 error) read back off fd 3.
type macBuilder struct {
	cmd   *exec.Cmd
	stdin io.WriteCloser
	ctrl  *bufio.Reader
	ctrlR *os.File
}

type buildRequest struct {
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
	cmd.Stderr = os.Stderr // ferry-macvm's own timestamped progress lines
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
// concatenated, and the exit code the guest agent reported. A type-4 frame
// (a malformed request, or the agent refusing to connect) surfaces as an
// error instead of a code, since no process ever ran.
func (b *macBuilder) run(argv []string, env map[string]string, cwd string) ([]byte, int32, error) {
	line, err := json.Marshal(buildRequest{Argv: argv, Env: env, Cwd: cwd})
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

// close ends the stdin stream, which is ferry-macvm's signal to shut the
// guest down and exit; then waits for it to actually do so.
func (b *macBuilder) close() error {
	b.stdin.Close()
	err := b.cmd.Wait()
	b.ctrlR.Close()
	return err
}
