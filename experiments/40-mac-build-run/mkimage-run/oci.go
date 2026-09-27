package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// image is a darwin/arm64 image to write: a root directory to package, and the
// runtime configuration the manifest records.
type image struct {
	Name       string
	Entrypoint []string
	Cmd        []string
	Env        []string
	WorkingDir string
	Labels     map[string]string
	RootFS     string
}

type descriptor struct {
	MediaType   string            `json:"mediaType"`
	Digest      string            `json:"digest"`
	Size        int64             `json:"size"`
	Annotations map[string]string `json:"annotations,omitempty"`
	Platform    map[string]string `json:"platform,omitempty"`
}

// written reports what writeLayout produced, for the one-line summary.
type written struct {
	layer    string
	manifest string
	size     int64
}

// writeLayout packages img.RootFS as a single gzipped layer and writes an OCI
// image layout at out, with os=darwin so ferry-darwin, not runc, is asked to
// run it.
func writeLayout(img *image, out string) (written, error) {
	if img.RootFS == "" {
		return written{}, fmt.Errorf("no root to package")
	}
	if err := os.RemoveAll(out); err != nil {
		return written{}, err
	}
	if err := os.MkdirAll(filepath.Join(out, "blobs", "sha256"), 0o755); err != nil {
		return written{}, err
	}

	raw, err := tarDir(img.RootFS)
	if err != nil {
		return written{}, err
	}
	diffID := sum(raw)
	gz, err := gzipBytes(raw)
	if err != nil {
		return written{}, err
	}
	layer, err := blob(out, "application/vnd.oci.image.layer.v1.tar+gzip", gz)
	if err != nil {
		return written{}, err
	}

	cfg := map[string]any{
		"architecture": "arm64",
		"os":           "darwin",
		"config":       imageConfig(img),
		"rootfs":       map[string]any{"type": "layers", "diff_ids": []string{diffID}},
	}
	cfgBytes, err := json.Marshal(cfg)
	if err != nil {
		return written{}, err
	}
	config, err := blob(out, "application/vnd.oci.image.config.v1+json", cfgBytes)
	if err != nil {
		return written{}, err
	}

	manifestBytes, err := json.Marshal(map[string]any{
		"schemaVersion": 2,
		"mediaType":     "application/vnd.oci.image.manifest.v1+json",
		"config":        config,
		"layers":        []descriptor{layer},
	})
	if err != nil {
		return written{}, err
	}
	m, err := blob(out, "application/vnd.oci.image.manifest.v1+json", manifestBytes)
	if err != nil {
		return written{}, err
	}
	tag := img.Name[strings.LastIndexByte(img.Name, ':')+1:]
	m.Annotations = map[string]string{
		"io.containerd.image.name":          img.Name,
		"org.opencontainers.image.ref.name": tag,
	}
	m.Platform = map[string]string{"os": "darwin", "architecture": "arm64"}

	indexBytes, err := json.Marshal(map[string]any{
		"schemaVersion": 2,
		"mediaType":     "application/vnd.oci.image.index.v1+json",
		"manifests":     []descriptor{m},
	})
	if err != nil {
		return written{}, err
	}
	if err := os.WriteFile(filepath.Join(out, "index.json"), indexBytes, 0o644); err != nil {
		return written{}, err
	}
	if err := os.WriteFile(filepath.Join(out, "oci-layout"), []byte(`{"imageLayoutVersion":"1.0.0"}`), 0o644); err != nil {
		return written{}, err
	}
	return written{layer: layer.Digest, manifest: m.Digest, size: layer.Size}, nil
}

// imageConfig is the OCI config's `config` object: only the fields a darwin
// image sets, and only when set, so an image that names none writes none.
func imageConfig(img *image) map[string]any {
	c := map[string]any{}
	if len(img.Entrypoint) > 0 {
		c["Entrypoint"] = img.Entrypoint
	}
	if len(img.Cmd) > 0 {
		c["Cmd"] = img.Cmd
	}
	if len(img.Env) > 0 {
		c["Env"] = img.Env
	}
	if img.WorkingDir != "" {
		c["WorkingDir"] = img.WorkingDir
	}
	if len(img.Labels) > 0 {
		c["Labels"] = img.Labels
	}
	return c
}

// tarDir writes dir's contents as a tar, every entry owned by root:wheel, in a
// stable (sorted) order so the same tree is the same bytes and so the same
// digest -- what makes a rebuild a cache hit rather than a new layer.
func tarDir(dir string) ([]byte, error) {
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	err := filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil || p == dir {
			return err
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		link := ""
		if info.Mode()&os.ModeSymlink != 0 {
			if link, err = os.Readlink(p); err != nil {
				return err
			}
		}
		hdr, err := tar.FileInfoHeader(info, link)
		if err != nil {
			return err
		}
		rel := strings.TrimPrefix(p, dir+string(os.PathSeparator))
		hdr.Name = filepath.ToSlash(rel)
		if d.IsDir() {
			hdr.Name += "/"
		}
		hdr.Uid, hdr.Gid, hdr.Uname, hdr.Gname = 0, 0, "root", "wheel"
		hdr.ModTime = time.Unix(0, 0)
		if err := tw.WriteHeader(hdr); err != nil {
			return err
		}
		if info.Mode().IsRegular() {
			f, err := os.Open(p)
			if err != nil {
				return err
			}
			defer f.Close()
			if _, err := io.Copy(tw, f); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if err := tw.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func gzipBytes(b []byte) ([]byte, error) {
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	if _, err := zw.Write(b); err != nil {
		return nil, err
	}
	if err := zw.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func sum(b []byte) string {
	h := sha256.Sum256(b)
	return "sha256:" + hex.EncodeToString(h[:])
}

func blob(out, mediaType string, b []byte) (descriptor, error) {
	d := sum(b)
	path := filepath.Join(out, "blobs", "sha256", strings.TrimPrefix(d, "sha256:"))
	if err := os.WriteFile(path, b, 0o644); err != nil {
		return descriptor{}, err
	}
	return descriptor{MediaType: mediaType, Digest: d, Size: int64(len(b))}, nil
}
