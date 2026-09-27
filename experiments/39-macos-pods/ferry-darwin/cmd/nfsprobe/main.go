// nfsprobe is what a hostile pod on a shared macOS machine would try: speak
// NFS from userspace, as an ordinary uid, to the NFS servers the runtime runs
// on 127.0.0.1 for volumes -- the kernel's nfsd, which exports the kubelet's
// pods directory with -mapall=root, and the per-PersistentVolume servers on
// loopback ports -- and list what they serve.
//
//	nfsprobe kernel DIR     MOUNT DIR from the kernel's mountd, then list it
//	nfsprobe scan LO HI     every listening loopback port in LO..HI, as a
//	                        per-PV server: MOUNT / and list it
//
// It prints one line per attempt: "open: ..." when it could read, "refused:
// ..." otherwise.
package main

import (
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/willscott/go-nfs-client/nfs"
	"github.com/willscott/go-nfs-client/nfs/rpc"
)

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: nfsprobe kernel DIR | nfsprobe scan LO HI")
		os.Exit(2)
	}
	fmt.Printf("nfsprobe as uid %d\n", os.Getuid())
	switch os.Args[1] {
	case "kernel":
		m, err := nfs.DialMount("127.0.0.1", time.Second)
		if err != nil {
			fmt.Printf("refused: kernel mountd: %v\n", err)
			return
		}
		list("kernel "+os.Args[2], m, os.Args[2])
	case "scan":
		lo, _ := strconv.Atoi(os.Args[2])
		hi, _ := strconv.Atoi(os.Args[3])
		found := 0
		for port := lo; port <= hi; port++ {
			c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 50*time.Millisecond)
			if err != nil {
				continue
			}
			c.Close()
			found++
			client, err := rpc.DialTCP("tcp", fmt.Sprintf("127.0.0.1:%d", port), false)
			if err != nil {
				fmt.Printf("refused: port %d: %v\n", port, err)
				continue
			}
			list(fmt.Sprintf("port %d", port), &nfs.Mount{Client: client}, "/")
		}
		fmt.Printf("%d listening loopback ports in %d..%d\n", found, lo, hi)
	}
}

func list(what string, m *nfs.Mount, dir string) {
	done := make(chan struct{})
	go func() {
		defer close(done)
		v, err := m.Mount(dir, rpc.NewAuthUnix("pod", uint32(os.Getuid()), uint32(os.Getgid())).Auth())
		if err != nil {
			fmt.Printf("refused: %s: MOUNT: %v\n", what, err)
			return
		}
		entries, err := v.ReadDirPlus(".")
		if err != nil {
			fmt.Printf("refused: %s: READDIR: %v\n", what, err)
			return
		}
		var names []string
		for _, e := range entries {
			if e.FileName != "." && e.FileName != ".." {
				names = append(names, e.FileName)
			}
		}
		fmt.Printf("open: %s: %s\n", what, strings.Join(names, " "))
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		fmt.Printf("refused: %s: no answer in 5 s\n", what)
	}
}
