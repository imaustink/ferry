// mkimage writes a directory as a one-layer darwin/arm64 OCI image layout,
// named the way ferry-registry keys what it serves.
//
//	mkimage -dir ROOT -name example.com/hello-darwin:1 -entrypoint /bin/hello -out LAYOUT
//
// A darwin image holds only the workload's own files. The OS it links against
// -- dyld and the shared cache -- comes from the node, because Apple's binaries
// are trusted where the OS put them and killed anywhere else.
package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"io"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"strings"
)

type descriptor struct {
	MediaType   string            `json:"mediaType"`
	Digest      string            `json:"digest"`
	Size        int64             `json:"size"`
	Annotations map[string]string `json:"annotations,omitempty"`
	Platform    map[string]string `json:"platform,omitempty"`
}

func main() {
	dir := flag.String("dir", "", "directory to package as the image's root")
	name := flag.String("name", "", "full image reference, e.g. example.com/hello-darwin:1")
	entrypoint := flag.String("entrypoint", "", "entrypoint, space separated")
	out := flag.String("out", "", "OCI layout directory to write")
	flag.Parse()
	if *dir == "" || *name == "" || *out == "" {
		flag.Usage()
		os.Exit(2)
	}
	_ = os.RemoveAll(*out)
	must(os.MkdirAll(filepath.Join(*out, "blobs", "sha256"), 0o755))

	// The layer: a tar of the directory, owned by root, gzipped.
	var raw bytes.Buffer
	tw := tar.NewWriter(&raw)
	must(filepath.WalkDir(*dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil || p == *dir {
			return err
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		hdr, err := tar.FileInfoHeader(info, "")
		if err != nil {
			return err
		}
		hdr.Name = strings.TrimPrefix(p, *dir+"/")
		if d.IsDir() {
			hdr.Name += "/"
		}
		hdr.Uid, hdr.Gid, hdr.Uname, hdr.Gname = 0, 0, "root", "wheel"
		if err := tw.WriteHeader(hdr); err != nil {
			return err
		}
		if info.Mode().IsRegular() {
			f, err := os.Open(p)
			if err != nil {
				return err
			}
			defer f.Close()
			_, err = io.Copy(tw, f)
			return err
		}
		return nil
	}))
	must(tw.Close())
	diffID := sum(raw.Bytes())
	var gz bytes.Buffer
	zw := gzip.NewWriter(&gz)
	_, _ = zw.Write(raw.Bytes())
	must(zw.Close())
	layer := blob(*out, "application/vnd.oci.image.layer.v1.tar+gzip", gz.Bytes())

	cfg := map[string]any{
		"architecture": "arm64",
		"os":           "darwin",
		"config":       map[string]any{"Entrypoint": strings.Fields(*entrypoint)},
		"rootfs":       map[string]any{"type": "layers", "diff_ids": []string{diffID}},
	}
	cfgBytes, _ := json.Marshal(cfg)
	config := blob(*out, "application/vnd.oci.image.config.v1+json", cfgBytes)

	manifest, _ := json.Marshal(map[string]any{
		"schemaVersion": 2,
		"mediaType":     "application/vnd.oci.image.manifest.v1+json",
		"config":        config,
		"layers":        []descriptor{layer},
	})
	m := blob(*out, "application/vnd.oci.image.manifest.v1+json", manifest)
	tag := (*name)[strings.LastIndexByte(*name, ':')+1:]
	m.Annotations = map[string]string{"io.containerd.image.name": *name, "org.opencontainers.image.ref.name": tag}
	m.Platform = map[string]string{"os": "darwin", "architecture": "arm64"}

	index, _ := json.Marshal(map[string]any{
		"schemaVersion": 2,
		"mediaType":     "application/vnd.oci.image.index.v1+json",
		"manifests":     []descriptor{m},
	})
	must(os.WriteFile(filepath.Join(*out, "index.json"), index, 0o644))
	must(os.WriteFile(filepath.Join(*out, "oci-layout"), []byte(`{"imageLayoutVersion":"1.0.0"}`), 0o644))
	log.Printf("%s: darwin/arm64, layer %s (%d bytes), manifest %s", *name, layer.Digest[:19], layer.Size, m.Digest[:19])
}

func sum(b []byte) string {
	h := sha256.Sum256(b)
	return "sha256:" + hex.EncodeToString(h[:])
}

func blob(out, mediaType string, b []byte) descriptor {
	d := sum(b)
	must(os.WriteFile(filepath.Join(out, "blobs", "sha256", strings.TrimPrefix(d, "sha256:")), b, 0o644))
	return descriptor{MediaType: mediaType, Digest: d, Size: int64(len(b))}
}

func must(err error) {
	if err != nil {
		log.Fatal(err)
	}
}
