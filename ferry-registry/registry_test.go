package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

// layout writes a one-image OCI layout named name, whose one layer is content,
// and returns its directory and the manifest's digest.
func layout(t *testing.T, name, content string) (string, string) {
	t.Helper()
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "blobs", "sha256"), 0o755)
	put := func(data []byte) descriptor {
		sum := sha256.Sum256(data)
		digest := "sha256:" + hex.EncodeToString(sum[:])
		os.WriteFile(blobPath(dir, digest), data, 0o644)
		return descriptor{Digest: digest, Size: int64(len(data))}
	}
	layer := put([]byte(content))
	layer.MediaType = "application/vnd.oci.image.layer.v1.tar"
	config := put([]byte(`{"architecture":"arm64","os":"linux"}`))
	config.MediaType = "application/vnd.oci.image.config.v1+json"
	data, _ := json.Marshal(map[string]any{
		"schemaVersion": 2, "mediaType": mediaOCIManifest,
		"config": config, "layers": []descriptor{layer},
	})
	manifest := put(data)
	manifest.MediaType = mediaOCIManifest
	manifest.Annotations = map[string]string{annotationImageName: name}
	idx, _ := json.Marshal(index{SchemaVersion: 2, Manifests: []descriptor{manifest}})
	os.WriteFile(filepath.Join(dir, "index.json"), idx, 0o644)
	os.WriteFile(filepath.Join(dir, "oci-layout"), []byte(`{"imageLayoutVersion":"1.0.0"}`), 0o644)
	return dir, manifest.Digest
}

func get(t *testing.T, url string) (*http.Response, string) {
	t.Helper()
	resp, err := http.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return resp, string(body)
}

func TestServesWhatWasAdded(t *testing.T) {
	store := t.TempDir()
	src, digest := layout(t, "docker.io/library/app:dev", "v1")
	added, err := add(store, src)
	if err != nil || len(added) != 1 || added[0] != "docker.io/library/app:dev" {
		t.Fatalf("add = %v, %v", added, err)
	}
	srv := httptest.NewServer(&registry{store: store})
	defer srv.Close()

	if resp, _ := get(t, srv.URL+"/v2/"); resp.StatusCode != 200 {
		t.Fatalf("/v2/ = %d", resp.StatusCode)
	}
	// How containerd asks a mirror for docker.io/library/app:dev.
	resp, body := get(t, srv.URL+"/v2/library/app/manifests/dev?ns=docker.io")
	if resp.StatusCode != 200 {
		t.Fatalf("manifest by tag = %d %s", resp.StatusCode, body)
	}
	if got := resp.Header.Get("Content-Type"); got != mediaOCIManifest {
		t.Errorf("content type %q", got)
	}
	if got := resp.Header.Get("Docker-Content-Digest"); got != digest {
		t.Errorf("digest %q, want %q", got, digest)
	}
	// And directly, with the whole name in the path.
	if resp, _ := get(t, srv.URL+"/v2/app/manifests/dev"); resp.StatusCode != 200 {
		t.Errorf("direct manifest = %d", resp.StatusCode)
	}
	if resp, _ := get(t, srv.URL+"/v2/library/app/manifests/"+digest+"?ns=docker.io"); resp.StatusCode != 200 {
		t.Errorf("manifest by digest = %d", resp.StatusCode)
	}

	var m children
	json.Unmarshal([]byte(body), &m)
	resp, layer := get(t, srv.URL+"/v2/library/app/blobs/"+m.Layers[0].Digest+"?ns=docker.io")
	if resp.StatusCode != 200 || layer != "v1" {
		t.Errorf("blob = %d %q", resp.StatusCode, layer)
	}

	// The same repository on another registry is another image, and falls
	// through to that registry.
	if resp, _ := get(t, srv.URL+"/v2/library/app/manifests/dev?ns=ghcr.io"); resp.StatusCode != 404 {
		t.Errorf("other registry = %d, want 404", resp.StatusCode)
	}
	if resp, _ := get(t, srv.URL+"/v2/library/app/blobs/sha256:../../etc?ns=docker.io"); resp.StatusCode != 400 {
		t.Errorf("bad digest = %d, want 400", resp.StatusCode)
	}
	req, _ := http.NewRequest(http.MethodPut, srv.URL+"/v2/library/app/manifests/dev", nil)
	if resp, _ := http.DefaultClient.Do(req); resp.StatusCode != 405 {
		t.Errorf("PUT = %d, want 405", resp.StatusCode)
	}
}

func TestReplacingAnImageCollectsTheOldOne(t *testing.T) {
	store := t.TempDir()
	first, oldDigest := layout(t, "app:dev", "v1")
	other, _ := layout(t, "quay.io/x/other:1", "other")
	second, newDigest := layout(t, "app:dev", "v2")
	for _, src := range []string{first, other, second} {
		if _, err := add(store, src); err != nil {
			t.Fatal(err)
		}
	}
	list, _ := names(store)
	if len(list) != 2 || list[0] != "docker.io/library/app:dev" || list[1] != "quay.io/x/other:1" {
		t.Fatalf("names = %v", list)
	}
	d, ok, _ := lookup(store, "docker.io/library/app:dev")
	if !ok || d.Digest != newDigest {
		t.Fatalf("app:dev = %s, want %s", d.Digest, newDigest)
	}
	if _, err := os.Stat(blobPath(store, oldDigest)); err == nil {
		t.Error("the replaced manifest is still on disk")
	}
	// Two manifests, one config they share, and two layers.
	entries, _ := os.ReadDir(filepath.Join(store, "blobs", "sha256"))
	if len(entries) != 5 {
		t.Errorf("%d blobs, want 5", len(entries))
	}
}

func TestNormalize(t *testing.T) {
	for in, want := range map[string]string{
		"busybox":                  "docker.io/library/busybox:latest",
		"bitnami/nginx:1":          "docker.io/bitnami/nginx:1",
		"quay.io/coreos/etcd":      "quay.io/coreos/etcd:latest",
		"localhost:5000/app":       "localhost:5000/app:latest",
		"docker.io/library/app:dv": "docker.io/library/app:dv",
	} {
		if got := normalize(in); got != want {
			t.Errorf("normalize(%q) = %q, want %q", in, got, want)
		}
	}
	if got := imageName(map[string]string{"org.opencontainers.image.ref.name": "dev"}); got != "" {
		t.Errorf("a bare tag named %q", got)
	}
}

func TestAnswersOnlyTheMachineNetwork(t *testing.T) {
	_, machines, _ := net.ParseCIDR("192.168.215.0/24")
	h := only([]*net.IPNet{machines}, &registry{store: t.TempDir()})
	for addr, want := range map[string]int{
		"192.168.215.7:40000": 200,
		"127.0.0.1:40000":     200,
		"192.168.1.40:40000":  403,
	} {
		req := httptest.NewRequest(http.MethodGet, "/v2/", nil)
		req.RemoteAddr = addr
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != want {
			t.Errorf("%s: %d, want %d", addr, rec.Code, want)
		}
	}
}

// criStore lays out what ferry-cri keeps: its blobs under content/, a
// state.json of descriptors by reference, and the names it was loaded with.
func criStore(t *testing.T, loaded string, images map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "content", "blobs", "sha256"), 0o755)
	state := map[string]descriptor{}
	for reference, content := range images {
		src, digest := layout(t, reference, content)
		blobs, _ := os.ReadDir(filepath.Join(src, "blobs", "sha256"))
		for _, b := range blobs {
			data, _ := os.ReadFile(filepath.Join(src, "blobs", "sha256", b.Name()))
			os.WriteFile(filepath.Join(dir, "content", "blobs", "sha256", b.Name()), data, 0o644)
		}
		state[reference] = descriptor{MediaType: mediaOCIManifest, Digest: digest}
	}
	data, _ := json.Marshal(state)
	os.WriteFile(filepath.Join(dir, "state.json"), data, 0o644)
	if loaded != "" {
		os.WriteFile(filepath.Join(dir, "loaded-images"), []byte(loaded), 0o644)
	}
	return dir
}

func TestImportsWhatFerryCRIWasLoadedWith(t *testing.T) {
	store := t.TempDir()
	cri := criStore(t, "docker.io/library/app:dev\nquay.io/x/gone:1\n", map[string]string{
		"docker.io/library/app:dev":      "app",
		"docker.io/library/busybox:1.36": "pulled",
	})
	added, err := importCRI(store, cri)
	if err != nil || len(added) != 1 || added[0] != "docker.io/library/app:dev" {
		t.Fatalf("import = %v, %v", added, err)
	}
	srv := httptest.NewServer(&registry{store: store})
	defer srv.Close()
	if resp, body := get(t, srv.URL+"/v2/library/app/manifests/dev?ns=docker.io"); resp.StatusCode != 200 {
		t.Fatalf("imported manifest = %d %s", resp.StatusCode, body)
	}
	// Pulled, so the machine pulls it too.
	if resp, _ := get(t, srv.URL+"/v2/library/busybox/manifests/1.36?ns=docker.io"); resp.StatusCode != 404 {
		t.Errorf("pulled image = %d, want 404", resp.StatusCode)
	}
	// Already held at that digest: nothing to do.
	if again, err := importCRI(store, cri); err != nil || len(again) != 0 {
		t.Errorf("second import = %v, %v", again, err)
	}
}

func TestImportsNothingFromAStoreThatWasNeverLoaded(t *testing.T) {
	cri := criStore(t, "", map[string]string{"docker.io/library/busybox:1.36": "pulled"})
	if added, err := importCRI(t.TempDir(), cri); err != nil || len(added) != 0 {
		t.Fatalf("import = %v, %v", added, err)
	}
	if added, err := importCRI(t.TempDir(), t.TempDir()); err != nil || len(added) != 0 {
		t.Fatalf("import of an empty directory = %v, %v", added, err)
	}
}
