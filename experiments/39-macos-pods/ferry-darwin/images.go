package main

// Pulling darwin images through ferry-registry.
//
// The registry is the read half of the distribution API, a mirror for every
// registry: GET /v2/<repository>/manifests/<tag>?ns=<registry host>, the form
// containerd uses for a mirror. So a pod's image reference means what it
// means on any other node. Only darwin/arm64 is accepted -- an image built for
// Linux would unpack here and fail at exec with nothing to say why.

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	securejoin "github.com/cyphar/filepath-securejoin"
	runtimeapi "k8s.io/cri-api/pkg/apis/runtime/v1"
)

type image struct {
	id         string // sha256:<config digest>
	refs       []string
	size       uint64
	rootfs     string
	entrypoint []string
	cmd        []string
	env        []string
	workdir    string
}

type imageSvc struct {
	runtimeapi.UnimplementedImageServiceServer
	mirror string
	dir    string
	mu     sync.Mutex
	images map[string]*image // by id and by every reference
}

// normalize matches ferry-registry's reference.go.
func normalize(ref string) (domain, repo, tag string) {
	domain, rest := "docker.io", ref
	if i := strings.IndexByte(ref, '/'); i >= 0 {
		if head := ref[:i]; head == "localhost" || strings.ContainsAny(head, ".:") {
			domain, rest = head, ref[i+1:]
		}
	}
	if domain == "docker.io" && !strings.Contains(rest, "/") {
		rest = "library/" + rest
	}
	repo, tag = rest, "latest"
	if i := strings.LastIndexByte(rest, ':'); i > strings.LastIndexByte(rest, '/') {
		repo, tag = rest[:i], rest[i+1:]
	}
	return
}

// imageRecord is an image's metadata beside its rootfs, so a restarted
// runtime still knows the images on disk -- and the image every running
// container was made from -- without pulling them again.
type imageRecord struct {
	ID         string   `json:"id"`
	Refs       []string `json:"refs"`
	Size       uint64   `json:"size"`
	Rootfs     string   `json:"rootfs"`
	Entrypoint []string `json:"entrypoint"`
	Cmd        []string `json:"cmd"`
	Env        []string `json:"env"`
	Workdir    string   `json:"workdir"`
}

func (s *imageSvc) add(img *image) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.images[img.id] = img
	for _, r := range img.refs {
		s.images[r] = img
	}
}

// load reads back every image on disk.
func (s *imageSvc) load() {
	recs, _ := filepath.Glob(filepath.Join(s.dir, "*", "image.json"))
	for _, p := range recs {
		var ir imageRecord
		if b, err := os.ReadFile(p); err != nil || json.Unmarshal(b, &ir) != nil {
			continue
		}
		s.add(&image{id: ir.ID, refs: ir.Refs, size: ir.Size, rootfs: ir.Rootfs,
			entrypoint: ir.Entrypoint, cmd: ir.Cmd, env: ir.Env, workdir: ir.Workdir})
	}
	if len(recs) > 0 {
		log.Printf("image: %d on disk", len(recs))
	}
}

// byID is the image with this id, or a stand-in carrying only the id when it
// has since been removed: a container's status names its image either way.
func (s *imageSvc) byID(id string) *image {
	s.mu.Lock()
	defer s.mu.Unlock()
	if img, ok := s.images[id]; ok {
		return img
	}
	return &image{id: id}
}

func (s *imageSvc) lookup(ref string) *image {
	s.mu.Lock()
	defer s.mu.Unlock()
	if img, ok := s.images[ref]; ok {
		return img
	}
	d, r, t := normalize(ref)
	return s.images[d+"/"+r+":"+t]
}

func (s *imageSvc) get(url string, accept string, into any) ([]byte, error) {
	req, _ := http.NewRequest("GET", url, nil)
	if accept != "" {
		req.Header.Set("Accept", accept)
	}
	resp, err := (&http.Client{Timeout: 5 * time.Minute}).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("GET %s: %s", url, resp.Status)
	}
	if into != nil {
		return body, json.Unmarshal(body, into)
	}
	return body, nil
}

type ociDescriptor struct {
	MediaType string            `json:"mediaType"`
	Digest    string            `json:"digest"`
	Size      int64             `json:"size"`
	Platform  map[string]string `json:"platform"`
}

func (s *imageSvc) PullImage(_ context.Context, req *runtimeapi.PullImageRequest) (*runtimeapi.PullImageResponse, error) {
	ref := req.Image.GetImage()
	if img := s.lookup(ref); img != nil {
		return &runtimeapi.PullImageResponse{ImageRef: img.id}, nil
	}
	start := time.Now()
	domain, repo, tag := normalize(ref)
	base := fmt.Sprintf("%s/v2/%s", s.mirror, repo)
	ns := "?ns=" + domain
	accept := "application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json," +
		"application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json"

	var m struct {
		MediaType string          `json:"mediaType"`
		Manifests []ociDescriptor `json:"manifests"`
		Config    ociDescriptor   `json:"config"`
		Layers    []ociDescriptor `json:"layers"`
	}
	if _, err := s.get(base+"/manifests/"+tag+ns, accept, &m); err != nil {
		return nil, err
	}
	if len(m.Manifests) > 0 {
		var pick string
		for _, d := range m.Manifests {
			if d.Platform["os"] == "darwin" && d.Platform["architecture"] == "arm64" {
				pick = d.Digest
			}
		}
		if pick == "" {
			return nil, fmt.Errorf("%s has no darwin/arm64 image", ref)
		}
		m.Manifests = nil
		if _, err := s.get(base+"/manifests/"+pick+ns, accept, &m); err != nil {
			return nil, err
		}
	}
	var cfg struct {
		OS           string `json:"os"`
		Architecture string `json:"architecture"`
		Config       struct {
			Entrypoint []string `json:"Entrypoint"`
			Cmd        []string `json:"Cmd"`
			Env        []string `json:"Env"`
			WorkingDir string   `json:"WorkingDir"`
		} `json:"config"`
	}
	if _, err := s.get(base+"/blobs/"+m.Config.Digest+ns, "", &cfg); err != nil {
		return nil, err
	}
	if cfg.OS != "darwin" || cfg.Architecture != "arm64" {
		return nil, fmt.Errorf("%s is %s/%s; this node runs darwin/arm64", ref, cfg.OS, cfg.Architecture)
	}

	img := &image{
		id: m.Config.Digest, refs: []string{domain + "/" + repo + ":" + tag},
		rootfs:     filepath.Join(s.dir, strings.TrimPrefix(m.Config.Digest, "sha256:"), "rootfs"),
		entrypoint: cfg.Config.Entrypoint, cmd: cfg.Config.Cmd, env: cfg.Config.Env, workdir: cfg.Config.WorkingDir,
	}
	_ = os.RemoveAll(filepath.Dir(img.rootfs))
	if err := os.MkdirAll(img.rootfs, 0o755); err != nil {
		return nil, err
	}
	for _, l := range m.Layers {
		body, err := s.get(base+"/blobs/"+l.Digest+ns, "", nil)
		if err != nil {
			return nil, err
		}
		img.size += uint64(len(body))
		if err := untar(body, strings.HasSuffix(l.MediaType, "gzip"), img.rootfs); err != nil {
			return nil, fmt.Errorf("layer %s: %w", l.Digest, err)
		}
	}
	s.add(img)
	saveJSON(filepath.Join(filepath.Dir(img.rootfs), "image.json"), imageRecord{
		ID: img.id, Refs: img.refs, Size: img.size, Rootfs: img.rootfs,
		Entrypoint: img.entrypoint, Cmd: img.cmd, Env: img.env, Workdir: img.workdir})
	log.Printf("image: pulled %s (%s, %d bytes) in %s", ref, img.id[:19], img.size, time.Since(start).Round(time.Millisecond))
	return &runtimeapi.PullImageResponse{ImageRef: img.id}, nil
}

// untar unpacks a layer, refusing any entry that would land outside root.
func untar(body []byte, gz bool, root string) error {
	var r io.Reader = strings.NewReader(string(body))
	if gz {
		z, err := gzip.NewReader(r)
		if err != nil {
			return err
		}
		r = z
	}
	tr := tar.NewReader(r)
	for {
		h, err := tr.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		// SecureJoin resolves each existing path component through root, so an
		// earlier symlink entry (its own name checked, but its target free to
		// point anywhere) cannot make a later entry land outside the image
		// root -- a lexical prefix check on the name alone would follow it.
		target, err := securejoin.SecureJoin(root, h.Name)
		if err != nil {
			return err
		}
		switch h.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, os.FileMode(h.Mode)&0o7777); err != nil {
				return err
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return err
			}
			f, err := os.OpenFile(target, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, os.FileMode(h.Mode)&0o7777)
			if err != nil {
				return err
			}
			if _, err := io.Copy(f, tr); err != nil {
				f.Close()
				return err
			}
			f.Close()
		case tar.TypeSymlink:
			_ = os.MkdirAll(filepath.Dir(target), 0o755)
			if err := os.Symlink(h.Linkname, target); err != nil {
				return err
			}
		}
	}
}

func (s *imageSvc) cri(img *image) *runtimeapi.Image {
	return &runtimeapi.Image{Id: img.id, RepoTags: img.refs, Size: img.size}
}

func (s *imageSvc) ImageStatus(_ context.Context, req *runtimeapi.ImageStatusRequest) (*runtimeapi.ImageStatusResponse, error) {
	// A miss is an empty response, not an error: that is how the kubelet is
	// told the image is absent and a pull is required.
	if img := s.lookup(req.Image.GetImage()); img != nil {
		return &runtimeapi.ImageStatusResponse{Image: s.cri(img)}, nil
	}
	return &runtimeapi.ImageStatusResponse{}, nil
}

func (s *imageSvc) ListImages(_ context.Context, _ *runtimeapi.ListImagesRequest) (*runtimeapi.ListImagesResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	seen := map[string]bool{}
	var out []*runtimeapi.Image
	for _, img := range s.images {
		if !seen[img.id] {
			seen[img.id] = true
			out = append(out, s.cri(img))
		}
	}
	return &runtimeapi.ListImagesResponse{Images: out}, nil
}

func (s *imageSvc) RemoveImage(_ context.Context, req *runtimeapi.RemoveImageRequest) (*runtimeapi.RemoveImageResponse, error) {
	img := s.lookup(req.Image.GetImage())
	if img == nil {
		return &runtimeapi.RemoveImageResponse{}, nil
	}
	s.mu.Lock()
	for k, v := range s.images {
		if v == img {
			delete(s.images, k)
		}
	}
	s.mu.Unlock()
	_ = os.RemoveAll(filepath.Dir(img.rootfs))
	return &runtimeapi.RemoveImageResponse{}, nil
}

func (s *imageSvc) ImageFsInfo(_ context.Context, _ *runtimeapi.ImageFsInfoRequest) (*runtimeapi.ImageFsInfoResponse, error) {
	var used uint64
	s.mu.Lock()
	for _, img := range s.images {
		used += img.size
	}
	s.mu.Unlock()
	fs := []*runtimeapi.FilesystemUsage{{
		Timestamp:  time.Now().UnixNano(),
		FsId:       &runtimeapi.FilesystemIdentifier{Mountpoint: s.dir},
		UsedBytes:  &runtimeapi.UInt64Value{Value: used},
		InodesUsed: &runtimeapi.UInt64Value{Value: 0},
	}}
	return &runtimeapi.ImageFsInfoResponse{ImageFilesystems: fs, ContainerFilesystems: fs}, nil
}
