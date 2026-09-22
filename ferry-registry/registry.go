package main

import (
	"fmt"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

// registry answers the three requests a pull makes -- the version check, a
// manifest by tag or digest, and a blob -- from the store.
type registry struct {
	store string
}

func (reg *registry) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Docker-Distribution-API-Version", "registry/2.0")
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		fail(w, http.StatusMethodNotAllowed, "UNSUPPORTED", "this registry is read-only")
		return
	}
	path := strings.TrimPrefix(r.URL.Path, "/v2/")
	if path == r.URL.Path {
		fail(w, http.StatusNotFound, "NOT_FOUND", "not a registry path")
		return
	}
	if path == "" {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte("{}"))
		return
	}

	if i := strings.LastIndex(path, "/manifests/"); i > 0 {
		reg.manifest(w, r, path[:i], path[i+len("/manifests/"):])
		return
	}
	if i := strings.LastIndex(path, "/blobs/"); i > 0 {
		digest := path[i+len("/blobs/"):]
		if !digestPattern.MatchString(digest) {
			fail(w, http.StatusBadRequest, "DIGEST_INVALID", "unsupported digest")
			return
		}
		reg.send(w, r, digest, "application/octet-stream")
		return
	}
	fail(w, http.StatusNotFound, "NOT_FOUND", "not a registry path")
}

// manifest serves a manifest by digest, or by the tag it is stored under.
//
// A mirror is asked for the repository alone -- `library/busybox`, not
// `docker.io/library/busybox` -- with the registry it stands in for in the `ns`
// parameter, which containerd adds to every mirror request. Without it,
// docker.io/foo/app and ghcr.io/foo/app would be the same image here. A request
// with no `ns` is someone talking to this registry directly, and names the whole
// reference in the path.
func (reg *registry) manifest(w http.ResponseWriter, r *http.Request, repo, ref string) {
	if strings.HasPrefix(ref, "sha256:") {
		if !digestPattern.MatchString(ref) {
			fail(w, http.StatusBadRequest, "DIGEST_INVALID", "unsupported digest")
			return
		}
		data, err := os.ReadFile(blobPath(reg.store, ref))
		if err != nil {
			fail(w, http.StatusNotFound, "MANIFEST_UNKNOWN", "no such manifest")
			return
		}
		reg.send(w, r, ref, sniff(data))
		return
	}

	name := repo
	if ns := r.URL.Query().Get("ns"); ns != "" {
		name = ns + "/" + repo
	}
	name = normalize(name + ":" + ref)
	d, ok, err := lookup(reg.store, name)
	if err != nil {
		fail(w, http.StatusInternalServerError, "UNKNOWN", err.Error())
		return
	}
	if !ok {
		fail(w, http.StatusNotFound, "MANIFEST_UNKNOWN", fmt.Sprintf("%s is not stored here", name))
		return
	}
	mediaType := d.MediaType
	if mediaType == "" {
		data, _ := os.ReadFile(blobPath(reg.store, d.Digest))
		mediaType = sniff(data)
	}
	reg.send(w, r, d.Digest, mediaType)
}

// send writes a blob by digest. http.ServeContent handles HEAD and ranges, so a
// resumed layer download works.
func (reg *registry) send(w http.ResponseWriter, r *http.Request, digest, mediaType string) {
	f, err := os.Open(blobPath(reg.store, digest))
	if err != nil {
		fail(w, http.StatusNotFound, "BLOB_UNKNOWN", "no such blob")
		return
	}
	defer f.Close()
	if mediaType == "" {
		mediaType = "application/octet-stream"
	}
	w.Header().Set("Content-Type", mediaType)
	w.Header().Set("Docker-Content-Digest", digest)
	w.Header().Set("Etag", strconv.Quote(digest))
	http.ServeContent(w, r, "", time.Time{}, f)
}

func fail(w http.ResponseWriter, code int, errCode, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	fmt.Fprintf(w, `{"errors":[{"code":%q,"message":%q}]}`, errCode, message)
}
