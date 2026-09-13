// Turning the image name someone wrote into the one a registry answers to.
//
// A manifest that says `busybox:1.36` or `nginx` is ordinary Kubernetes, and
// every other runtime accepts it: the reference parser fills in the parts that
// were left out. ferry's image store does not -- it wants a domain and rejects
// anything else with "invalid domain for image reference", which turns a normal
// manifest into a pod that never starts. So the filling in happens here, by the
// same rules containerd and Docker use.

import Foundation

enum ImageReference {
    /// The default registry, and the namespace bare names live in on it.
    static let defaultDomain = "docker.io"
    static let officialNamespace = "library"

    /// Expands a reference to its fully qualified form.
    ///
    ///     busybox              -> docker.io/library/busybox:latest
    ///     busybox:1.36         -> docker.io/library/busybox:1.36
    ///     bitnami/nginx        -> docker.io/bitnami/nginx:latest
    ///     quay.io/coreos/etcd  -> quay.io/coreos/etcd:latest
    ///     localhost:5000/app   -> localhost:5000/app:latest
    ///     alpine@sha256:abc... -> docker.io/library/alpine@sha256:abc...
    ///
    /// A reference that is already qualified comes back unchanged, so this is
    /// safe to apply to anything arriving from the kubelet.
    static func normalize(_ reference: String) -> String {
        let reference = reference.trimmingCharacters(in: .whitespaces)
        guard !reference.isEmpty else { return reference }

        var domain = ""
        var remainder = reference

        // The first path component is a registry only if it looks like a host:
        // it carries a dot or a port, or it is exactly localhost. Without that
        // test `bitnami/nginx` would read bitnami as a registry.
        if let slash = reference.firstIndex(of: "/") {
            let head = String(reference[..<slash])
            if head == "localhost" || head.contains(".") || head.contains(":") {
                domain = head
                remainder = String(reference[reference.index(after: slash)...])
            }
        }

        if domain.isEmpty {
            domain = defaultDomain
            // Only Docker Hub has the notion of official images living under a
            // namespace that callers are allowed to omit.
            if !remainder.contains("/") {
                remainder = "\(officialNamespace)/\(remainder)"
            }
        }

        return "\(domain)/\(withTag(remainder))"
    }

    /// Adds `:latest` unless the path already carries a tag or a digest. The
    /// search starts after the last slash so that a port in the domain -- which
    /// is not part of `path` -- can never be mistaken for a tag.
    private static func withTag(_ path: String) -> String {
        if path.contains("@") { return path }
        let lastComponent = path.split(separator: "/").last ?? ""
        if lastComponent.contains(":") { return path }
        return "\(path):latest"
    }
}
