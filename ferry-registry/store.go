package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
)

// The store is one OCI image layout: blobs by digest, and an index.json whose
// entries carry the name each image answers to. That is the format `ferry image
// load` already hands around, so adding to the store is copying blobs and
// rewriting one small file -- no push protocol, and nothing to run while
// adding.

const (
	mediaOCIIndex        = "application/vnd.oci.image.index.v1+json"
	mediaOCIManifest     = "application/vnd.oci.image.manifest.v1+json"
	mediaDockerList      = "application/vnd.docker.distribution.manifest.list.v2+json"
	mediaDockerManifest  = "application/vnd.docker.distribution.manifest.v2+json"
	annotationImageName  = "io.containerd.image.name"
	annotationSubject    = "io.containerd.manifest.subject"
	annotationDockerType = "vnd.docker.reference.type"
)

var digestPattern = regexp.MustCompile(`^sha256:[a-f0-9]{64}$`)

type descriptor struct {
	MediaType    string            `json:"mediaType,omitempty"`
	Digest       string            `json:"digest"`
	Size         int64             `json:"size"`
	Annotations  map[string]string `json:"annotations,omitempty"`
	Platform     json.RawMessage   `json:"platform,omitempty"`
	ArtifactType string            `json:"artifactType,omitempty"`
}

type index struct {
	SchemaVersion int          `json:"schemaVersion"`
	MediaType     string       `json:"mediaType,omitempty"`
	Manifests     []descriptor `json:"manifests"`
}

// What a manifest or an index points at. Both shapes in one struct, since only
// the fields that are present get filled.
type children struct {
	MediaType string       `json:"mediaType"`
	Manifests []descriptor `json:"manifests"`
	Config    *descriptor  `json:"config"`
	Layers    []descriptor `json:"layers"`
}

func isIndex(mediaType string) bool {
	return mediaType == mediaOCIIndex || mediaType == mediaDockerList
}

func isManifest(mediaType string) bool {
	return mediaType == mediaOCIManifest || mediaType == mediaDockerManifest
}

// sniff works out what a manifest blob is when nothing said. The media type is
// optional in an OCI manifest and an index, and a registry has to send one.
func sniff(data []byte) string {
	var c children
	if json.Unmarshal(data, &c) != nil {
		return ""
	}
	switch {
	case c.MediaType != "":
		return c.MediaType
	case c.Manifests != nil:
		return mediaOCIIndex
	case c.Config != nil:
		return mediaOCIManifest
	}
	return ""
}

func blobPath(root, digest string) string {
	return filepath.Join(root, "blobs", "sha256", digest[len("sha256:"):])
}

func readIndex(root string) (index, error) {
	var idx index
	data, err := os.ReadFile(filepath.Join(root, "index.json"))
	if errors.Is(err, fs.ErrNotExist) {
		return index{SchemaVersion: 2, MediaType: mediaOCIIndex}, nil
	}
	if err != nil {
		return idx, err
	}
	if err := json.Unmarshal(data, &idx); err != nil {
		return idx, fmt.Errorf("%s/index.json: %w", root, err)
	}
	return idx, nil
}

// lookup finds the descriptor stored under a fully qualified name.
func lookup(root, name string) (descriptor, bool, error) {
	idx, err := readIndex(root)
	if err != nil {
		return descriptor{}, false, err
	}
	for i := len(idx.Manifests) - 1; i >= 0; i-- {
		if idx.Manifests[i].Annotations[annotationImageName] == name {
			return idx.Manifests[i], true, nil
		}
	}
	return descriptor{}, false, nil
}

// walk visits d and everything it reaches whose blob is present under root.
//
// A missing blob is not an error below the top. `docker save` of a
// multi-platform image writes the whole index and the blobs of one platform, and
// the store keeps that index as it is: a machine asks for its own platform and
// never goes near the others.
func walk(root string, d descriptor, visit func(descriptor) error) error {
	if !digestPattern.MatchString(d.Digest) {
		return fmt.Errorf("unsupported digest %q", d.Digest)
	}
	if err := visit(d); err != nil {
		return err
	}
	// A descriptor without a media type is allowed, and has to be opened to
	// find out whether it points at anything.
	if d.MediaType != "" && !isIndex(d.MediaType) && !isManifest(d.MediaType) {
		return nil
	}
	data, err := os.ReadFile(blobPath(root, d.Digest))
	if err != nil {
		return nil
	}
	var c children
	if err := json.Unmarshal(data, &c); err != nil {
		if d.MediaType == "" {
			return nil // a layer or a config, not JSON worth reading
		}
		return fmt.Errorf("%s: %w", d.Digest, err)
	}
	next := append([]descriptor{}, c.Manifests...)
	if c.Config != nil {
		next = append(next, *c.Config)
	}
	next = append(next, c.Layers...)
	for _, child := range next {
		if _, err := os.Stat(blobPath(root, child.Digest)); err != nil {
			continue
		}
		if err := walk(root, child, visit); err != nil {
			return err
		}
	}
	return nil
}

// add merges the named images in the layout at src into the store, replacing
// whatever was stored under the same names, and returns the names.
func add(store, src string) ([]string, error) {
	incoming, err := readIndex(src)
	if err != nil {
		return nil, err
	}
	if len(incoming.Manifests) == 0 {
		return nil, fmt.Errorf("%s has no index.json entries", src)
	}
	added, err := merge(store, src, incoming.Manifests)
	if err == nil && len(added) == 0 {
		return nil, fmt.Errorf("no named images in %s", src)
	}
	return added, err
}

// The files of ferry-cri's image store that say what it holds. state.json is
// Containerization's own record, a descriptor per reference, with the blobs in
// content/ laid out as an OCI layout's are. loaded-images is ferry-cri's: the
// names that came from `ferry image load` rather than a registry, one a line.
const (
	criState  = "state.json"
	criLoaded = "loaded-images"
	criBlobs  = "content"
)

// importCRI adds every image ferry-cri was loaded with that the store does not
// already hold at the same digest, and returns the names it added.
//
// `ferry image load` adds an image here only while the registry is enabled, so
// without this, turning it on served none of what the Mac already had: every
// image had to be loaded again. Only loaded images: one ferry-cri pulled is
// better pulled by the machine from where it came, since served from here a
// mutable tag would stay whatever this Mac last saw.
func importCRI(store, cri string) ([]string, error) {
	loaded, err := os.ReadFile(filepath.Join(cri, criLoaded))
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	wanted := map[string]bool{}
	for _, line := range strings.Split(string(loaded), "\n") {
		if name := normalize(line); name != "" {
			wanted[name] = true
		}
	}
	data, err := os.ReadFile(filepath.Join(cri, criState))
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var state map[string]descriptor
	if err := json.Unmarshal(data, &state); err != nil {
		return nil, fmt.Errorf("%s: %w", filepath.Join(cri, criState), err)
	}
	current, err := readIndex(store)
	if err != nil {
		return nil, err
	}
	stored := map[string]string{} // name -> digest
	for _, entry := range current.Manifests {
		stored[entry.Annotations[annotationImageName]] = entry.Digest
	}
	var entries []descriptor
	seen := map[string]bool{}
	for reference, d := range state {
		name := normalize(reference)
		if !wanted[name] || seen[name] || stored[name] == d.Digest {
			continue
		}
		seen[name] = true
		d.Annotations = map[string]string{annotationImageName: name}
		entries = append(entries, d)
	}
	if len(entries) == 0 {
		return nil, nil
	}
	sort.Slice(entries, func(i, j int) bool {
		return entries[i].Annotations[annotationImageName] < entries[j].Annotations[annotationImageName]
	})
	return merge(store, filepath.Join(cri, criBlobs), entries)
}

// merge copies the named entries, and everything they reach, from the layout
// whose blobs are under src into the store.
func merge(store, src string, incoming []descriptor) ([]string, error) {
	if err := os.MkdirAll(filepath.Join(store, "blobs", "sha256"), 0o755); err != nil {
		return nil, err
	}
	unlock, err := lock(store)
	if err != nil {
		return nil, err
	}
	defer unlock()

	current, err := readIndex(store)
	if err != nil {
		return nil, err
	}

	var added []string
	for _, entry := range incoming {
		// BuildKit's attestations sit beside the image with no name of their
		// own; ferry-cri drops them for the same reason.
		if entry.Annotations[annotationSubject] != "" ||
			entry.Annotations[annotationDockerType] == "attestation-manifest" {
			continue
		}
		name := imageName(entry.Annotations)
		if name == "" {
			fmt.Fprintf(os.Stderr, "skipping %s: no image name in the layout\n", entry.Digest)
			continue
		}
		if _, err := os.Stat(blobPath(src, entry.Digest)); err != nil {
			return nil, fmt.Errorf("%s: %s is not in the layout", name, entry.Digest)
		}
		if err := walk(src, entry, func(d descriptor) error {
			return copyBlob(blobPath(src, d.Digest), blobPath(store, d.Digest))
		}); err != nil {
			return nil, fmt.Errorf("%s: %w", name, err)
		}

		kept := current.Manifests[:0]
		for _, existing := range current.Manifests {
			if existing.Annotations[annotationImageName] != name {
				kept = append(kept, existing)
			}
		}
		stored := entry
		stored.Annotations = map[string]string{annotationImageName: name}
		current.Manifests = append(kept, stored)
		added = append(added, name)
	}
	if len(added) == 0 {
		return nil, nil
	}

	if err := writeFile(filepath.Join(store, "oci-layout"), []byte(`{"imageLayoutVersion":"1.0.0"}`)); err != nil {
		return nil, err
	}
	data, err := json.MarshalIndent(current, "", "  ")
	if err != nil {
		return nil, err
	}
	if err := writeFile(filepath.Join(store, "index.json"), data); err != nil {
		return nil, err
	}
	// Images that are rebuilt all day replace their names, and the layers the
	// old versions used would otherwise stay on the disk for ever.
	if err := collect(store, current); err != nil {
		return added, fmt.Errorf("collecting unused blobs: %w", err)
	}
	return added, nil
}

// collect removes blobs nothing in the index reaches.
func collect(store string, idx index) error {
	live := map[string]bool{}
	for _, entry := range idx.Manifests {
		if err := walk(store, entry, func(d descriptor) error {
			live[d.Digest[len("sha256:"):]] = true
			return nil
		}); err != nil {
			return err
		}
	}
	dir := filepath.Join(store, "blobs", "sha256")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if !live[e.Name()] {
			os.Remove(filepath.Join(dir, e.Name()))
		}
	}
	return nil
}

// names lists what the store answers to, sorted.
func names(store string) ([]string, error) {
	idx, err := readIndex(store)
	if err != nil {
		return nil, err
	}
	var out []string
	for _, entry := range idx.Manifests {
		if name := entry.Annotations[annotationImageName]; name != "" {
			out = append(out, name)
		}
	}
	sort.Strings(out)
	return out, nil
}

// lock holds the store against a second add running at the same time.
func lock(store string) (func(), error) {
	f, err := os.OpenFile(filepath.Join(store, ".lock"), os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		f.Close()
		return nil, err
	}
	return func() { syscall.Flock(int(f.Fd()), syscall.LOCK_UN); f.Close() }, nil
}

// copyBlob links a blob into place where the filesystem allows, and copies it
// where it does not. Blobs are named by their content, so one already present
// is already right.
func copyBlob(from, to string) error {
	if _, err := os.Stat(to); err == nil {
		return nil
	}
	if err := os.Link(from, to); err == nil {
		return nil
	}
	in, err := os.Open(from)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp, err := os.CreateTemp(filepath.Dir(to), ".blob-*")
	if err != nil {
		return err
	}
	if _, err := io.Copy(tmp, in); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	return os.Rename(tmp.Name(), to)
}

// writeFile replaces a file in one step, so the server never reads half of one.
func writeFile(path string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tmp-*")
	if err != nil {
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	return os.Rename(tmp.Name(), path)
}
