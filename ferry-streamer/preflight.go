package main

// Can this machine's ferry binaries actually reach the cluster?
//
// macOS 15 and later gate access to the local network per program. A binary that
// has not been granted it gets EHOSTUNREACH -- "no route to host" -- for LAN
// addresses while the route is perfectly good, the host answers ping, and
// /usr/bin/curl to the very same address succeeds, because system binaries are
// exempt. It is a confusing failure to meet in a kubelet log, so ferry checks for
// it before joining and says what it means.
//
// The grant follows the program that launched ferry, which is why this shows up
// over SSH and not in Terminal: an SSH session has nobody to show a prompt to.

import (
	"fmt"
	"net"
	"os"
	"time"
)

func preflight(server string) int {
	conn, err := net.DialTimeout("tcp", server, 8*time.Second)
	if err == nil {
		conn.Close()
		fmt.Println("reachable")
		return 0
	}
	fmt.Printf("unreachable: %v\n", err)
	return 1
}

func init() {
	// Deliberately not a flag: this runs before anything else is set up, and the
	// caller is a shell script checking one thing.
	if len(os.Args) == 3 && os.Args[1] == "--preflight" {
		os.Exit(preflight(os.Args[2]))
	}
}
