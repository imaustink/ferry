package main

import (
	"archive/tar"
	"compress/gzip"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"testing"
)

// readImage decodes the OCI layout writeLayout produced: the manifest, the
// config, and the set of paths in the single layer.
type readImage struct {
	os         string
	arch       string
	entrypoint []string
	cmd        []string
	env        []string
	workingDir string
	layerPaths map[string]bool
}

func loadLayout(t *testing.T, out string) readImage {
	t.Helper()
	indexRaw, err := os.ReadFile(filepath.Join(out, "index.json"))
	if err != nil {
		t.Fatalf("index.json: %v", err)
	}
	var index struct {
		Manifests []descriptor `json:"manifests"`
	}
	if err := json.Unmarshal(indexRaw, &index); err != nil {
		t.Fatalf("index: %v", err)
	}
	if len(index.Manifests) != 1 {
		t.Fatalf("want 1 manifest, got %d", len(index.Manifests))
	}
	if p := index.Manifests[0].Platform["os"]; p != "darwin" {
		t.Errorf("index platform os = %q, want darwin", p)
	}

	var manifest struct {
		Config descriptor   `json:"config"`
		Layers []descriptor `json:"layers"`
	}
	readBlob(t, out, index.Manifests[0].Digest, &manifest)
	if len(manifest.Layers) != 1 {
		t.Fatalf("want 1 layer, got %d", len(manifest.Layers))
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
	readBlob(t, out, manifest.Config.Digest, &cfg)

	return readImage{
		os:         cfg.OS,
		arch:       cfg.Architecture,
		entrypoint: cfg.Config.Entrypoint,
		cmd:        cfg.Config.Cmd,
		env:        cfg.Config.Env,
		workingDir: cfg.Config.WorkingDir,
		layerPaths: layerPaths(t, out, manifest.Layers[0].Digest),
	}
}

func readBlob(t *testing.T, out, digest string, v any) {
	t.Helper()
	raw, err := os.ReadFile(blobPath(out, digest))
	if err != nil {
		t.Fatalf("blob %s: %v", digest, err)
	}
	if err := json.Unmarshal(raw, v); err != nil {
		t.Fatalf("decode %s: %v", digest, err)
	}
}

func layerPaths(t *testing.T, out, digest string) map[string]bool {
	t.Helper()
	f, err := os.Open(blobPath(out, digest))
	if err != nil {
		t.Fatalf("layer: %v", err)
	}
	defer f.Close()
	zr, err := gzip.NewReader(f)
	if err != nil {
		t.Fatalf("gzip: %v", err)
	}
	paths := map[string]bool{}
	tr := tar.NewReader(zr)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatalf("tar: %v", err)
		}
		paths[hdr.Name] = true
		if hdr.Uname != "root" || hdr.Gname != "wheel" {
			t.Errorf("%s owned by %s:%s, want root:wheel", hdr.Name, hdr.Uname, hdr.Gname)
		}
	}
	return paths
}

func blobPath(out, digest string) string {
	return filepath.Join(out, "blobs", "sha256", digest[len("sha256:"):])
}

func writeCtx(t *testing.T, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for name, body := range files {
		full := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func TestDockerfileImage(t *testing.T) {
	ctx := writeCtx(t, map[string]string{
		"Dockerfile": `# a darwin workload
FROM scratch
COPY bin/app /bin/app
COPY assets/ /assets/
ENV FOO=bar BAZ=qux
WORKDIR /work
ENTRYPOINT ["/bin/app", "serve"]
CMD ["--port", "8080"]
`,
		"bin/app":         "binary",
		"assets/logo.txt": "logo",
	})
	out := filepath.Join(t.TempDir(), "layout")

	img := &image{Name: "example.com/app-darwin:1"}
	if err := buildFromDockerfile(img, filepath.Join(ctx, "Dockerfile"), ctx); err != nil {
		t.Fatalf("build: %v", err)
	}
	defer os.RemoveAll(img.RootFS)
	if _, err := writeLayout(img, out); err != nil {
		t.Fatalf("writeLayout: %v", err)
	}

	got := loadLayout(t, out)
	if got.os != "darwin" || got.arch != "arm64" {
		t.Errorf("platform = %s/%s, want darwin/arm64", got.os, got.arch)
	}
	if want := []string{"/bin/app", "serve"}; !eq(got.entrypoint, want) {
		t.Errorf("entrypoint = %v, want %v", got.entrypoint, want)
	}
	if want := []string{"--port", "8080"}; !eq(got.cmd, want) {
		t.Errorf("cmd = %v, want %v", got.cmd, want)
	}
	if want := []string{"FOO=bar", "BAZ=qux"}; !eq(got.env, want) {
		t.Errorf("env = %v, want %v", got.env, want)
	}
	if got.workingDir != "/work" {
		t.Errorf("workingDir = %q, want /work", got.workingDir)
	}
	for _, p := range []string{"bin/app", "assets/logo.txt"} {
		if !got.layerPaths[p] {
			t.Errorf("layer missing %q; has %v", p, keys(got.layerPaths))
		}
	}
}

func TestShellFormEntrypoint(t *testing.T) {
	ctx := writeCtx(t, map[string]string{
		"Dockerfile": "FROM scratch\nCOPY app /app\nENTRYPOINT /app --serve\n",
		"app":        "x",
	})
	img := &image{Name: "example.com/app-darwin:1"}
	if err := buildFromDockerfile(img, filepath.Join(ctx, "Dockerfile"), ctx); err != nil {
		t.Fatalf("build: %v", err)
	}
	defer os.RemoveAll(img.RootFS)
	want := []string{"/bin/sh", "-c", "/app --serve"}
	if !eq(img.Entrypoint, want) {
		t.Errorf("entrypoint = %v, want %v", img.Entrypoint, want)
	}
}

func TestRunIsRejected(t *testing.T) {
	_, err := parseDockerfile("FROM scratch\nRUN make\n")
	if err == nil {
		t.Fatal("RUN should be rejected")
	}
}

func TestFromMustBeScratch(t *testing.T) {
	if _, err := parseDockerfile("FROM alpine:3\n"); err == nil {
		t.Fatal("non-scratch FROM should be rejected")
	}
	if _, err := parseDockerfile("COPY a b\n"); err == nil {
		t.Fatal("missing FROM should be rejected")
	}
}

func TestCopyEscapeRejected(t *testing.T) {
	ctx := writeCtx(t, map[string]string{"Dockerfile": "FROM scratch\nCOPY ../secret /x\n"})
	img := &image{Name: "x:1"}
	err := buildFromDockerfile(img, filepath.Join(ctx, "Dockerfile"), ctx)
	if img.RootFS != "" {
		defer os.RemoveAll(img.RootFS)
	}
	if err == nil {
		t.Fatal("COPY escaping the context should be rejected")
	}
}

func eq(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func keys(m map[string]bool) []string {
	var out []string
	for k := range m {
		out = append(out, k)
	}
	return out
}
