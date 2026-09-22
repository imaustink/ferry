package main

import "strings"

// normalize expands an image reference to its fully qualified form, by the
// rules containerd and Docker use and ferry-cri's ImageReference.normalize
// follows. The two have to agree: a name ferry-cri answers to on the Mac is the
// name a machine asks this registry for.
//
//	busybox              -> docker.io/library/busybox:latest
//	bitnami/nginx:1      -> docker.io/bitnami/nginx:1
//	quay.io/coreos/etcd  -> quay.io/coreos/etcd:latest
//	localhost:5000/app   -> localhost:5000/app:latest
func normalize(reference string) string {
	reference = strings.TrimSpace(reference)
	if reference == "" {
		return ""
	}
	domain, remainder := "", reference
	// The first component is a registry only if it looks like a host, or
	// `bitnami/nginx` would read bitnami as one.
	if slash := strings.IndexByte(reference, '/'); slash >= 0 {
		head := reference[:slash]
		if head == "localhost" || strings.ContainsAny(head, ".:") {
			domain, remainder = head, reference[slash+1:]
		}
	}
	if domain == "" {
		domain = "docker.io"
		if !strings.Contains(remainder, "/") {
			remainder = "library/" + remainder
		}
	}
	if !strings.Contains(remainder, "@") {
		last := remainder[strings.LastIndexByte(remainder, '/')+1:]
		if !strings.Contains(last, ":") {
			remainder += ":latest"
		}
	}
	return domain + "/" + remainder
}

// imageName is the name an index entry is stored under, or "" when it has none
// worth keeping.
//
// containerd and Docker write the full name as io.containerd.image.name. The
// OCI annotation is sometimes the full name (podman) and sometimes only the tag
// (Docker writes both), and a bare tag names nothing: normalizing "dev" would
// store the image as docker.io/library/dev:latest.
func imageName(annotations map[string]string) string {
	if name := annotations["io.containerd.image.name"]; name != "" {
		return normalize(name)
	}
	if name := annotations["org.opencontainers.image.ref.name"]; strings.ContainsAny(name, "/:") {
		return normalize(name)
	}
	return ""
}
