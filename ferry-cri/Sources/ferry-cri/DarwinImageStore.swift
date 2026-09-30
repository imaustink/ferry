// Fetching a darwin pod image for a host VM sandbox.
//
// A `FROM macos` image is an ordinary one-layer OCI image whose layer holds only
// the workload's own arm64 files (dyld and the system libraries come from the
// guest's baked OS base). ferry-cri runs on the host and already knows this Mac's
// registry (--image-mirror, the same ferry-registry a machine node pulls from),
// so it fetches the image host-side over that registry's HTTP API and hands the
// bytes to the guest over the agent -- no guest networking needed. This closes
// the "container root" gap: DarwinRuntime assembles the guest's OS base plus this
// layer under a chroot and runs the entrypoint there.
//
// Verified by compilation and by DarwinImageStoreTests (the manifest/config
// parsing and command resolution, the parts that do not need a live registry).

import Foundation

/// What a darwin image contributes to a container: its run configuration and the
/// single layer's tar bytes (as served -- the guest's `tar` auto-detects gzip).
struct DarwinImage: Sendable {
    var entrypoint: [String]
    var cmd: [String]
    var env: [String]
    var workingDir: String
    var layer: Data
}

enum DarwinImageError: Error, CustomStringConvertible {
    case noMirror
    case notFound(String)
    case malformed(String)

    var description: String {
        switch self {
        case .noMirror:
            return "ferry-cri has no registry to pull a macOS image from (--image-mirror unset); "
                + "a darwin image is served by ferry-registry, so machines must be on"
        case .notFound(let m): return m
        case .malformed(let m): return m
        }
    }
}

enum DarwinImageStore {
    private static let manifestAccept = [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    ].joined(separator: ", ")

    // MARK: OCI JSON (only the fields we read)

    struct Descriptor: Codable, Sendable {
        var mediaType: String?
        var digest: String
        var size: Int64?
        var platform: Platform?
    }

    /// The identity the kubelet needs for a darwin image to count as present: a
    /// non-empty id and a non-zero size (it rejects an ImageStatus missing
    /// either with ImageInspectError).
    struct Identity: Sendable {
        var id: String
        var size: Int64
    }
    struct Platform: Codable, Sendable {
        var os: String?
        var architecture: String?
    }
    struct Manifest: Codable, Sendable {
        var mediaType: String?
        var config: Descriptor?
        var layers: [Descriptor]?
        var manifests: [Descriptor]?  // present when this is an index
    }
    struct ImageConfig: Codable, Sendable {
        struct Config: Codable, Sendable {
            var Entrypoint: [String]?
            var Cmd: [String]?
            var Env: [String]?
            var WorkingDir: String?
        }
        var os: String?
        var architecture: String?
        var config: Config?
    }

    /// Whether the registry holds this reference as a darwin image, without
    /// pulling the layer. The kubelet asks ImageService to pull/inspect an image
    /// before the sandbox runs and does not say which OS it is for, so this is how
    /// a darwin pod's image is recognised there (an index's darwin/arm64 child, or
    /// a plain manifest whose config says os darwin).
    static func isDarwin(_ reference: String,
                         session: URLSession = .shared,
                         mirror: String? = ImageMirror.address) async -> Bool {
        await resolveDarwin(reference, session: session, mirror: mirror) != nil
    }

    /// If the registry holds this reference as a darwin image, its identity for
    /// the kubelet: the config digest as id and the config + layer sizes as size.
    /// Nil for a non-darwin image or a miss. No layer is downloaded.
    static func resolveDarwin(_ reference: String,
                              session: URLSession = .shared,
                              mirror: String? = ImageMirror.address) async -> Identity? {
        guard let mirror else { return nil }
        let canonical = ImageReference.normalize(reference)
        let (repository, ref) = ImageMirror.split(canonical)
        do {
            let m = try await manifest(repository: repository, ref: ref, mirror: mirror, session: session)
            guard let configDesc = m.config, let layerDesc = m.layers?.first else { return nil }
            let configData = try await blob(repository: repository, digest: configDesc.digest,
                                            mirror: mirror, session: session)
            guard let cfg = try? JSONDecoder().decode(ImageConfig.self, from: configData),
                  cfg.os == "darwin" else { return nil }
            let size = (configDesc.size ?? 0) + (layerDesc.size ?? 0)
            return Identity(id: configDesc.digest, size: size > 0 ? size : 1)
        } catch { return nil }
    }

    /// Fetch an image's run config and layer from this Mac's registry mirror.
    static func fetch(_ reference: String,
                      session: URLSession = .shared,
                      mirror: String? = ImageMirror.address) async throws -> DarwinImage {
        guard let mirror else { throw DarwinImageError.noMirror }
        let canonical = ImageReference.normalize(reference)
        let (repository, ref) = ImageMirror.split(canonical)

        let manifest = try await manifest(repository: repository, ref: ref, mirror: mirror, session: session)
        guard let configDesc = manifest.config,
              let layerDesc = manifest.layers?.first else {
            throw DarwinImageError.malformed("\(reference): manifest has no config or layer")
        }
        let configData = try await blob(repository: repository, digest: configDesc.digest, mirror: mirror, session: session)
        let cfg = (try? JSONDecoder().decode(ImageConfig.self, from: configData))?.config
        let layer = try await blob(repository: repository, digest: layerDesc.digest, mirror: mirror, session: session)

        return DarwinImage(
            entrypoint: cfg?.Entrypoint ?? [],
            cmd: cfg?.Cmd ?? [],
            env: cfg?.Env ?? [],
            workingDir: cfg?.WorkingDir ?? "",
            layer: layer)
    }

    /// Resolves the manifest, following one index level to the darwin/arm64 entry.
    private static func manifest(repository: String, ref: String, mirror: String,
                                 session: URLSession) async throws -> Manifest {
        let first = try await manifestBlob(repository: repository, ref: ref, mirror: mirror, session: session)
        let parsed = try decodeManifest(first, reference: ref)
        // A plain manifest already has a config + layers.
        if parsed.config != nil, parsed.layers != nil { return parsed }
        // Otherwise it is an index: pick the darwin/arm64 child and fetch it.
        guard let children = parsed.manifests, !children.isEmpty else {
            throw DarwinImageError.malformed("\(ref): neither a manifest nor an index")
        }
        let pick = children.first { $0.platform?.os == "darwin" && $0.platform?.architecture == "arm64" }
            ?? children[0]
        let childData = try await blob(repository: repository, digest: pick.digest, mirror: mirror, session: session)
        return try decodeManifest(childData, reference: pick.digest)
    }

    static func decodeManifest(_ data: Data, reference: String) throws -> Manifest {
        guard let m = try? JSONDecoder().decode(Manifest.self, from: data) else {
            throw DarwinImageError.malformed("\(reference): unreadable manifest JSON")
        }
        return m
    }

    private static func manifestBlob(repository: String, ref: String, mirror: String,
                                     session: URLSession) async throws -> Data {
        guard let url = URL(string: "http://\(mirror)/v2/\(repository)/manifests/\(ref)") else {
            throw DarwinImageError.malformed("bad manifest URL for \(repository):\(ref)")
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(manifestAccept, forHTTPHeaderField: "Accept")
        return try await body(request, session: session, what: "manifest \(repository):\(ref)")
    }

    private static func blob(repository: String, digest: String, mirror: String,
                             session: URLSession) async throws -> Data {
        guard let url = URL(string: "http://\(mirror)/v2/\(repository)/blobs/\(digest)") else {
            throw DarwinImageError.malformed("bad blob URL for \(digest)")
        }
        return try await body(URLRequest(url: url, timeoutInterval: 120), session: session,
                              what: "blob \(digest)")
    }

    private static func body(_ request: URLRequest, session: URLSession, what: String) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch { throw DarwinImageError.notFound("fetching \(what): \(error)") }
        guard let http = response as? HTTPURLResponse else {
            throw DarwinImageError.notFound("fetching \(what): no HTTP response")
        }
        guard http.statusCode == 200 else {
            throw DarwinImageError.notFound("fetching \(what): registry returned \(http.statusCode)")
        }
        return data
    }

    /// The command a container runs, resolving CRI overrides against the image
    /// the way the kubelet expects: the container's `command` replaces the image
    /// entrypoint, its `args` replace the image cmd, and each is taken from the
    /// image when the container leaves it empty. Pure, so it is unit-tested.
    static func resolvedCommand(image: DarwinImage,
                                command: [String], args: [String]) -> [String] {
        let entry = command.isEmpty ? image.entrypoint : command
        let params = command.isEmpty ? (args.isEmpty ? image.cmd : args) : args
        let argv = entry + params
        return argv.isEmpty ? ["/usr/bin/true"] : argv
    }
}
