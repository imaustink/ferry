package main

import "errors"

// parseArgs reads FILE MOUNTPOINT ro|rw. Kept out of main_linux.go so it is
// built, vetted and tested on the Mac that builds ferry-loop.
func parseArgs(args []string) (file, mountpoint string, readOnly bool, err error) {
	usage := errors.New("usage: ferry-loop FILE MOUNTPOINT ro|rw")
	if len(args) != 3 || args[0] == "" || args[1] == "" {
		return "", "", false, usage
	}
	switch args[2] {
	case "ro":
		readOnly = true
	case "rw":
	default:
		return "", "", false, usage
	}
	return args[0], args[1], readOnly, nil
}
