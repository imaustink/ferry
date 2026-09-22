// Trimming an OCI layout to what this node can run, before it is loaded.
//
// `docker save` of a multi-platform image writes the image's whole index --
// seventeen platforms for something like nginx -- and the blobs of only the
// one platform it actually has. ImageStore.load walks every manifest the index
// lists with no platform filter and fails on the first one whose content is
// not there, as `missingContent("sha256:...")`: no image named, no platform
// named, and an archive that holds a perfectly good linux/arm64 image refused.
//
// The store cannot be asked for one platform, so the layout is given one
// instead. Each index is rewritten to list only this node's platform, and only
// manifests whose content is present; the rewritten index is a new blob with a
// new digest, written into a scratch copy of the layout so the caller's
// directory is never modified.

import ContainerizationOCI
import CryptoKit
import Foundation

enum NodeLayout {
    /// What a pod VM runs. Every image this node pulls or loads is for this.
    static let platform = ContainerizationOCI.Platform(arch: "arm64", os: "linux", variant: "v8")

    /// The directory to load from: `source` itself when nothing in it needs
    /// dropping, otherwise a trimmed layout under `scratch`, which the caller
    /// removes afterwards.
    static func prepare(source: URL, scratch: URL) throws -> URL {
        let index = try JSONDecoder().decode(
            Index.self, from: Data(contentsOf: source.appending(component: "index.json")))

        var trimmer = Trimmer(source: source, scratch: scratch)
        var kept: [Descriptor] = []
        for entry in index.manifests {
            let name = imageName(entry)
            guard let result = try trimmer.trim(entry, image: name) else {
                throw RuntimeFailure.invalid(trimmer.explainMissing(image: name))
            }
            kept.append(result)
        }
        guard trimmer.changed else { return source }

        // The trimmed layout: fresh control files, and every blob the source
        // had, linked rather than copied where the filesystem allows. The
        // rewritten indexes are already in place from trimming.
        let blobs = source.appending(component: "blobs")
        let fm = FileManager.default
        for algorithm in (try? fm.contentsOfDirectory(atPath: blobs.path())) ?? [] {
            let from = blobs.appending(component: algorithm)
            let to = scratch.appending(component: "blobs").appending(component: algorithm)
            try fm.createDirectory(at: to, withIntermediateDirectories: true)
            for blob in (try? fm.contentsOfDirectory(atPath: from.path())) ?? [] {
                let target = to.appending(component: blob)
                guard !fm.fileExists(atPath: target.path()) else { continue }
                do {
                    try fm.linkItem(at: from.appending(component: blob), to: target)
                } catch {
                    try fm.copyItem(at: from.appending(component: blob), to: target)
                }
            }
        }
        try Data(#"{"imageLayoutVersion":"1.0.0"}"#.utf8)
            .write(to: scratch.appending(component: "oci-layout"))
        let trimmed = Index(schemaVersion: index.schemaVersion,
                            mediaType: index.mediaType.isEmpty ? MediaTypes.index : index.mediaType,
                            manifests: kept, annotations: index.annotations,
                            subject: index.subject, artifactType: index.artifactType)
        try JSONEncoder().encode(trimmed).write(to: scratch.appending(component: "index.json"))
        return scratch
    }

    /// The name an entry will be registered under, for messages.
    private static func imageName(_ entry: Descriptor) -> String {
        entry.annotations?["io.containerd.image.name"]
            ?? entry.annotations?["org.opencontainers.image.ref.name"]
            ?? entry.digest
    }

    private struct Trimmer {
        let source: URL
        let scratch: URL
        /// Whether anything was dropped, which is whether a new layout is needed.
        var changed = false
        /// Platforms the archive lists, and this platform's manifests whose
        /// content is missing, so a refusal can say what was actually there.
        var listed: [String] = []
        var missing: [String] = []

        init(source: URL, scratch: URL) {
            self.source = source
            self.scratch = scratch
        }

        func blobURL(_ digest: String) -> URL? {
            let parts = digest.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return source.appending(component: "blobs")
                .appending(component: String(parts[0])).appending(component: String(parts[1]))
        }

        func present(_ descriptor: Descriptor) -> Bool {
            guard let url = blobURL(descriptor.digest) else { return false }
            return FileManager.default.fileExists(atPath: url.path())
        }

        /// The descriptor to keep in place of `descriptor`, or nil when nothing
        /// under it can run here.
        mutating func trim(_ descriptor: Descriptor, image: String) throws -> Descriptor? {
            switch descriptor.mediaType {
            case MediaTypes.index, MediaTypes.dockerManifestList:
                guard present(descriptor), let url = blobURL(descriptor.digest) else {
                    missing.append(descriptor.digest)
                    return nil
                }
                let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: url))
                var kept: [Descriptor] = []
                var dropped = false
                for child in index.manifests {
                    if let result = try trim(child, image: image) {
                        if result != child { dropped = true }
                        kept.append(result)
                    } else {
                        dropped = true
                    }
                }
                guard !kept.isEmpty else { return nil }
                guard dropped else { return descriptor }

                changed = true
                let rewritten = Index(schemaVersion: index.schemaVersion,
                                      mediaType: index.mediaType.isEmpty ? descriptor.mediaType : index.mediaType,
                                      manifests: kept, annotations: index.annotations,
                                      subject: index.subject, artifactType: index.artifactType)
                let data = try JSONEncoder().encode(rewritten)
                let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let dir = scratch.appending(component: "blobs").appending(component: "sha256")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: dir.appending(component: hex))
                return Descriptor(mediaType: descriptor.mediaType, digest: "sha256:\(hex)",
                                  size: Int64(data.count), urls: descriptor.urls,
                                  annotations: descriptor.annotations, platform: descriptor.platform,
                                  artifactType: descriptor.artifactType)

            case MediaTypes.imageManifest, MediaTypes.dockerManifest:
                if let platform = descriptor.platform {
                    listed.append(platform.description)
                    // Attestations and other platforms: not runnable here.
                    guard platform == NodeLayout.platform else { return nil }
                }
                guard present(descriptor), let url = blobURL(descriptor.digest) else {
                    missing.append(descriptor.digest)
                    return nil
                }
                let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
                if let absent = ([manifest.config] + manifest.layers).first(where: { !present($0) }) {
                    missing.append(absent.digest)
                    return nil
                }
                return descriptor

            default:
                return descriptor
            }
        }

        func explainMissing(image: String) -> String {
            let want = NodeLayout.platform.description
            let platforms = Array(Set(listed)).sorted()
            var message = "image \(image) has nothing this node can run (\(want))"
            if !platforms.isEmpty {
                message += "; the archive lists \(platforms.joined(separator: ", "))"
            }
            if !missing.isEmpty {
                message += ", but its content for \(want) is not in it (missing \(missing[0]))"
            }
            return message + ". Export it for this platform, e.g. `docker save --platform \(want)`, "
                + "or pull it from a registry."
        }
    }
}
