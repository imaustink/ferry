package main

// PersistentVolumes, served by the runtime itself.
//
// ferry-storage makes a PersistentVolume a directory on the Mac, and ferry-node
// shares the Mac's volumes directory into the machine over virtiofs at the
// same path. Volumes on the node's own disk reach a container root through
// the kernel's nfsd (volumes.go), but that nfsd will not export a directory on
// a virtiofs mount: it left the share out of its exports and said nothing.
//
// A userspace NFS server does not care what it serves. So each PersistentVolume
// directory a container mounts gets a go-nfs server of its own on a loopback
// port, rooted at that directory -- bound, so a symlink cannot lead out of it --
// and the container root mounts it like any other volume. A pod sees its own
// claim and nothing else of the share, which a single mount of the whole share
// into the root would not give.

import (
	"fmt"
	"log"
	"net"
	"sync"

	"github.com/go-git/go-billy/v5/osfs"
	nfs "github.com/willscott/go-nfs"
	nfshelper "github.com/willscott/go-nfs/helpers"
)

type pvServers struct {
	mu     sync.Mutex
	byPath map[string]int // directory -> loopback port
}

// portFor serves dir over NFS on 127.0.0.1, once, and says where.
func (p *pvServers) portFor(dir string) (int, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if port, ok := p.byPath[dir]; ok {
		return port, nil
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	fs := osfs.New(dir, osfs.WithBoundOS())
	handler := nfshelper.NewCachingHandler(nfshelper.NewNullAuthHandler(fs), 4096)
	go func() {
		if err := nfs.Serve(ln, handler); err != nil {
			log.Printf("volumes: the NFS server for %s stopped: %v", dir, err)
		}
	}()
	port := ln.Addr().(*net.TCPAddr).Port
	if p.byPath == nil {
		p.byPath = map[string]int{}
	}
	p.byPath[dir] = port
	log.Printf("volumes: serving %s over NFS on 127.0.0.1:%d", dir, port)
	return port, nil
}

// mountPV mounts a PersistentVolume directory at target through its server.
func (p *pvServers) mountPV(dir, target string, readOnly bool) error {
	port, err := p.portFor(dir)
	if err != nil {
		return err
	}
	opts := fmt.Sprintf("vers=3,tcp,port=%d,mountport=%d,locallocks,nobrowse,nosuid,nodev", port, port)
	if readOnly {
		opts += ",rdonly"
	}
	return run("mount_nfs", "-o", opts, "127.0.0.1:/", target)
}
