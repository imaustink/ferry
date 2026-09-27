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
//
// The servers take no credentials, so what keeps one pod out of another's
// claim is who may connect: only from a reserved port, below 1024, which only
// root can bind -- the kernel's NFS client, mounting with resvport -- and a
// pod's processes are not root. Without it, a pod on a shared machine could
// speak NFS from userspace to 127.0.0.1 and read any claim mounted there.
//
// Each server is a process of its own, `ferry-darwin pvserve DIR`, not a
// goroutine of the runtime's. In the runtime, the servers died with it and
// every pod with a claim was left with a mount whose server was gone -- a hard
// NFS mount, so anything touching the claim hung. Out of it, they outlive a
// restart; the runtime keeps a record of each (dir, port, pid) and a restarted
// one finds them there, still serving the mounts the pods already have.

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"

	"github.com/go-git/go-billy/v5/osfs"
	nfs "github.com/willscott/go-nfs"
	nfshelper "github.com/willscott/go-nfs/helpers"
)

type pvServers struct {
	dir    string // where the records are kept
	mu     sync.Mutex
	byPath map[string]pvRecord // served directory -> its server
}

type pvRecord struct {
	Dir  string `json:"dir"`
	Port int    `json:"port"`
	Pid  int    `json:"pid"`
	Boot string `json:"boot"` // a record from an earlier boot names a pid that is not ours
}

func (p *pvServers) recordPath(dir string) string {
	sum := sha256.Sum256([]byte(dir))
	return filepath.Join(p.dir, hex.EncodeToString(sum[:8])+".json")
}

// load finds the servers an earlier runtime started that are still running.
func (p *pvServers) load() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.byPath = map[string]pvRecord{}
	_ = os.MkdirAll(p.dir, 0o755)
	boot := bootSession()
	recs, _ := filepath.Glob(filepath.Join(p.dir, "*.json"))
	for _, path := range recs {
		var rec pvRecord
		if b, err := os.ReadFile(path); err != nil || json.Unmarshal(b, &rec) != nil ||
			rec.Boot != boot || !isOurs(rec.Pid, "pvserve") {
			_ = os.Remove(path)
			continue
		}
		p.byPath[rec.Dir] = rec
	}
	if len(p.byPath) > 0 {
		log.Printf("volumes: %d PersistentVolume servers still running", len(p.byPath))
	}
}

// portFor serves dir over NFS on 127.0.0.1, once, and says where.
func (p *pvServers) portFor(dir string) (int, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if rec, ok := p.byPath[dir]; ok && alive(rec.Pid) {
		return rec.Port, nil
	}
	self, err := os.Executable()
	if err != nil {
		return 0, err
	}
	rd, wr, err := os.Pipe()
	if err != nil {
		return 0, err
	}
	defer rd.Close()
	logf, _ := os.OpenFile(strings.TrimSuffix(p.recordPath(dir), ".json")+".log", os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	cmd := exec.Command(self, "pvserve", dir)
	cmd.Stdout, cmd.Stderr = logf, logf
	cmd.ExtraFiles = []*os.File{wr}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true} // outlives the runtime
	if err := cmd.Start(); err != nil {
		wr.Close()
		return 0, err
	}
	wr.Close()
	if logf != nil {
		logf.Close()
	}
	buf := make([]byte, 256)
	n, _ := rd.Read(buf)
	msg := strings.TrimSpace(string(buf[:n]))
	portStr, ok := strings.CutPrefix(msg, "ok ")
	port, err := strconv.Atoi(portStr)
	if !ok || err != nil {
		_ = cmd.Wait()
		return 0, fmt.Errorf("serving %s: %s", dir, msg)
	}
	go func() { _ = cmd.Wait() }() // reaped if it ever ends while we are here
	rec := pvRecord{Dir: dir, Port: port, Pid: cmd.Process.Pid, Boot: bootSession()}
	p.byPath[dir] = rec
	saveJSON(p.recordPath(dir), rec)
	log.Printf("volumes: serving %s over NFS on 127.0.0.1:%d (pid %d)", dir, port, rec.Pid)
	return port, nil
}

// runPVServer is `ferry-darwin pvserve DIR`: one PersistentVolume's server. It
// reports "ok <port>" on fd 3 once it is listening.
func runPVServer(dir string) {
	report := os.NewFile(3, "report")
	tcp, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		fmt.Fprintf(report, "err %v\n", err)
		os.Exit(1)
	}
	fs := osfs.New(dir, osfs.WithBoundOS())
	handler := nfshelper.NewCachingHandler(nfshelper.NewNullAuthHandler(fs), 4096)
	fmt.Fprintf(report, "ok %d\n", tcp.Addr().(*net.TCPAddr).Port)
	report.Close()
	if err := nfs.Serve(reservedOnly{tcp}, handler); err != nil {
		log.Printf("volumes: the NFS server for %s stopped: %v", dir, err)
		os.Exit(1)
	}
}

// mountPV mounts a PersistentVolume directory at target through its server.
func (p *pvServers) mountPV(dir, target string, readOnly bool) error {
	port, err := p.portFor(dir)
	if err != nil {
		return err
	}
	opts := fmt.Sprintf("vers=3,tcp,resvport,port=%d,mountport=%d,locallocks,nobrowse,nosuid,nodev", port, port)
	if readOnly {
		opts += ",rdonly"
	}
	return run("mount_nfs", "-o", opts, "127.0.0.1:/", target)
}

// reservedOnly refuses a connection from an unreserved port: see the top of
// this file.
type reservedOnly struct{ net.Listener }

func (l reservedOnly) Accept() (net.Conn, error) {
	for {
		c, err := l.Listener.Accept()
		if err != nil {
			return nil, err
		}
		if a, ok := c.RemoteAddr().(*net.TCPAddr); ok && a.Port < 1024 {
			return c, nil
		}
		log.Printf("volumes: refused an NFS connection from %s: not a reserved port, so not root", c.RemoteAddr())
		c.Close()
	}
}
