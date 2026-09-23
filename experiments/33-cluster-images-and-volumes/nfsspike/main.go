// Spike: an unprivileged NFSv3 server on the Mac whose chown is real to its
// clients. Ownership is kept in an xattr on the Mac's file, since the server
// runs as the Mac user and cannot chown for real. New files take their
// directory's owner, since go-nfs does not pass the caller's AUTH_UNIX
// credential down to the filesystem.
package main

import (
	"fmt"
	"log"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	billy "github.com/go-git/go-billy/v5"
	"github.com/go-git/go-billy/v5/osfs"
	nfs "github.com/willscott/go-nfs"
	nfsfile "github.com/willscott/go-nfs/file"
	nfshelper "github.com/willscott/go-nfs/helpers"
	"golang.org/x/sys/unix"
)

const ownerAttr = "dev.ferry.owner"

type ownerFS struct {
	billy.Filesystem
	root string
}

func (o *ownerFS) real(p string) string { return filepath.Join(o.root, filepath.Clean("/"+p)) }

func readOwner(path string) (uint32, uint32, bool) {
	buf := make([]byte, 64)
	n, err := unix.Getxattr(path, ownerAttr, buf)
	if err != nil {
		return 0, 0, false
	}
	parts := strings.SplitN(string(buf[:n]), ":", 2)
	if len(parts) != 2 {
		return 0, 0, false
	}
	u, _ := strconv.ParseUint(parts[0], 10, 32)
	g, _ := strconv.ParseUint(parts[1], 10, 32)
	return uint32(u), uint32(g), true
}

func writeOwner(path string, uid, gid uint32) error {
	return unix.Setxattr(path, ownerAttr, []byte(fmt.Sprintf("%d:%d", uid, gid)), 0)
}

// inherit gives a new entry its directory's owner.
func (o *ownerFS) inherit(p string) {
	parent := filepath.Dir(o.real(p))
	if u, g, ok := readOwner(parent); ok {
		writeOwner(o.real(p), u, g)
	}
}

type info struct {
	os.FileInfo
	sys nfsfile.FileInfo
}

func (i info) Sys() any { return i.sys }

func (o *ownerFS) wrap(p string, fi os.FileInfo) os.FileInfo {
	if fi == nil {
		return fi
	}
	base := nfsfile.GetInfo(fi)
	sys := nfsfile.FileInfo{Nlink: 1}
	if base != nil {
		sys = *base
	}
	sys.UID, sys.GID = 0, 0
	if u, g, ok := readOwner(o.real(p)); ok {
		sys.UID, sys.GID = u, g
	}
	return info{fi, sys}
}

func (o *ownerFS) Stat(p string) (os.FileInfo, error) {
	fi, err := o.Filesystem.Stat(p)
	return o.wrap(p, fi), err
}

func (o *ownerFS) Lstat(p string) (os.FileInfo, error) {
	fi, err := o.Filesystem.Lstat(p)
	return o.wrap(p, fi), err
}

func (o *ownerFS) ReadDir(p string) ([]os.FileInfo, error) {
	list, err := o.Filesystem.ReadDir(p)
	for i, fi := range list {
		list[i] = o.wrap(filepath.Join(p, fi.Name()), fi)
	}
	return list, err
}

func (o *ownerFS) Create(p string) (billy.File, error) {
	f, err := o.Filesystem.Create(p)
	if err == nil {
		o.inherit(p)
	}
	return f, err
}

func (o *ownerFS) OpenFile(p string, flag int, perm os.FileMode) (billy.File, error) {
	_, statErr := os.Lstat(o.real(p))
	f, err := o.Filesystem.OpenFile(p, flag, perm)
	if err == nil && flag&os.O_CREATE != 0 && os.IsNotExist(statErr) {
		o.inherit(p)
	}
	// go-nfs answers every WRITE with FILE_SYNC and opens and closes the file
	// around it; without this nothing it acknowledged had reached the disk.
	if err == nil && durable && flag&(os.O_WRONLY|os.O_RDWR) != 0 {
		return syncOnClose{f}, nil
	}
	return f, err
}

var durable = os.Getenv("NFS_DURABLE") == "1"

type syncOnClose struct{ billy.File }

func (s syncOnClose) Close() error {
	if f, ok := s.File.(interface{ Sync() error }); ok {
		f.Sync()
	}
	return s.File.Close()
}

func (o *ownerFS) MkdirAll(p string, perm os.FileMode) error {
	err := o.Filesystem.MkdirAll(p, perm)
	if err == nil {
		o.inherit(p)
	}
	return err
}

func (o *ownerFS) Symlink(target, link string) error {
	err := o.Filesystem.Symlink(target, link)
	if err == nil {
		o.inherit(link)
	}
	return err
}

// billy.Change

func (o *ownerFS) Chmod(p string, mode os.FileMode) error { return os.Chmod(o.real(p), mode) }

func (o *ownerFS) Lchown(p string, uid, gid int) error {
	return writeOwner(o.real(p), uint32(uid), uint32(gid))
}

func (o *ownerFS) Chown(p string, uid, gid int) error { return o.Lchown(p, uid, gid) }

func (o *ownerFS) Chtimes(p string, atime, mtime time.Time) error {
	return os.Chtimes(o.real(p), atime, mtime)
}

func main() {
	if len(os.Args) != 3 {
		log.Fatal("usage: nfsspike DIR ADDR")
	}
	root, _ := filepath.Abs(os.Args[1])
	os.MkdirAll(root, 0o755)
	l, err := net.Listen("tcp", os.Args[2])
	if err != nil {
		log.Fatal(err)
	}
	fs := &ownerFS{Filesystem: osfs.New(root), root: root}
	handler := nfshelper.NewCachingHandler(nfshelper.NewNullAuthHandler(fs), 4096)
	log.Printf("serving %s on %s", root, l.Addr())
	log.Fatal(nfs.Serve(l, handler))
}
