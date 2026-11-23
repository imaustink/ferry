package main

import (
	"errors"
	"path"
	"strconv"
	"strings"
)

// command is what ferry-loop was asked to do. Parsed here rather than in
// main_linux.go so it is built, vetted and tested on the Mac that builds it.
type command struct {
	op       string // "mount", "attach" or "rm"
	file     string // the disk image (mount, attach)
	target   string // mountpoint (mount) or directory (rm)
	readOnly bool
	device   int // the loop device number (attach)
}

const usage = `usage: ferry-loop FILE MOUNTPOINT ro|rw
       ferry-loop attach FILE ro|rw N
       ferry-loop rm DIR`

// removable is the only tree rm will delete beneath: the pod's volumes,
// where its scratch disk holds each container's upper directory.
const removable = "/run/volumes/"

func parseCommand(args []string) (command, error) {
	bad := errors.New(usage)
	mode := func(s string) (bool, error) {
		switch s {
		case "ro":
			return true, nil
		case "rw":
			return false, nil
		}
		return false, bad
	}
	switch {
	case len(args) == 2 && args[0] == "rm":
		dir := args[1]
		// Absolute, already clean, and strictly beneath removable: nothing
		// that a "..", a doubled slash or the root itself could widen.
		if dir != path.Clean(dir) || !strings.HasPrefix(dir, removable) || len(dir) == len(removable) {
			return command{}, bad
		}
		return command{op: "rm", target: dir}, nil
	case len(args) == 4 && args[0] == "attach":
		ro, err := mode(args[2])
		if err != nil || args[1] == "" {
			return command{}, bad
		}
		n, err := strconv.Atoi(args[3])
		if err != nil || n < 0 || n > 1<<20 {
			return command{}, bad
		}
		return command{op: "attach", file: args[1], readOnly: ro, device: n}, nil
	case len(args) == 3 && args[0] != "attach" && args[0] != "rm":
		ro, err := mode(args[2])
		if err != nil || args[0] == "" || args[1] == "" {
			return command{}, bad
		}
		return command{op: "mount", file: args[0], target: args[1], readOnly: ro}, nil
	}
	return command{}, bad
}
