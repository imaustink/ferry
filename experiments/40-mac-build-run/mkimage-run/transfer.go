package main

import (
	"archive/tar"
	"bytes"
	"encoding/base64"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// guestRoot is the one directory a build ever touches inside the builder VM.
// COPY lands here (pushed as a tar over the exec channel -- see pushCopy),
// RUN's cwd defaults to it, and the whole tree is read back once, at the end
// (pullRoot), to become the image's single layer.
const guestRoot = "/private/var/ferry/build"

// pushCopy stages c the same way ferry-mkimage's COPY does -- into a throwaway
// host directory, using its exact rules for file-vs-directory and dest naming
// -- then ships that directory into the guest as a tar. It never places
// anything under a shared or virtiofs-mounted path: those denied "Operation
// not permitted" on the com.apple.provenance every file created by this
// harness carries (see FINDINGS.md). A tar shipped as bytes over the agent's
// own exec channel carries no such tag once the guest writes it to its own
// disk.
func pushCopy(b *macBuilder, context string, c copyOp) error {
	tmp, err := os.MkdirTemp("", "mkimage-run-copy-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	if err := applyCopy(context, tmp, c); err != nil {
		return err
	}
	raw, err := tarDir(tmp) // tmp already mirrors the image root after this COPY
	if err != nil {
		return err
	}
	return pushTar(b, raw)
}

func pushTar(b *macBuilder, raw []byte) error {
	encoded := base64.StdEncoding.EncodeToString(raw)
	cmd := fmt.Sprintf("mkdir -p '%s' && printf '%%s' '%s' | base64 -d | tar -x -C '%s'", guestRoot, encoded, guestRoot)
	stdout, code, err := b.run([]string{"/bin/sh", "-c", cmd}, nil, "")
	if err != nil {
		return err
	}
	if code != 0 {
		return fmt.Errorf("pushing files into the guest: exit %d: %s", code, stdout)
	}
	return nil
}

// pullRoot tars the guest's whole build root and reads it back over the same
// channel, once, after every COPY and RUN has run -- the point at which the
// image's one layer is whatever is left in guestRoot.
func pullRoot(b *macBuilder, destHost string) error {
	stdout, code, err := b.run([]string{"/bin/sh", "-c", fmt.Sprintf("tar -C '%s' -c . | base64", guestRoot)}, nil, "")
	if err != nil {
		return err
	}
	if code != 0 {
		return fmt.Errorf("collecting the build root: tar exit %d", code)
	}
	clean := strings.Map(func(r rune) rune {
		if r == '\n' || r == '\r' || r == ' ' {
			return -1
		}
		return r
	}, string(stdout))
	raw, err := base64.StdEncoding.DecodeString(clean)
	if err != nil {
		return fmt.Errorf("decoding the build root: %w", err)
	}
	return untar(raw, destHost)
}

func untar(raw []byte, dest string) error {
	tr := tar.NewReader(bytes.NewReader(raw))
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		target := filepath.Join(dest, filepath.FromSlash(hdr.Name))
		switch hdr.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
		case tar.TypeSymlink:
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return err
			}
			_ = os.Remove(target)
			if err := os.Symlink(hdr.Linkname, target); err != nil {
				return err
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return err
			}
			f, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, os.FileMode(hdr.Mode))
			if err != nil {
				return err
			}
			if _, err := io.Copy(f, tr); err != nil {
				f.Close()
				return err
			}
			f.Close()
		}
	}
}
