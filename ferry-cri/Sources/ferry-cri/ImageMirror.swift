// This Mac's registry, asked before the real one.
//
// `ferry image load` puts an image into one node's store, and every other
// node -- a second node on this Mac, a node on another Mac -- had never heard
// of it, so a pod scheduled there failed with ErrImagePull. ferry-registry
// holds every image loaded on this Mac and asks the other Macs for what it does
// not hold, so a pull that tries it first finds a loaded image wherever it was
// loaded. It answers 404 for everything else, which is where the real registry
// takes over, exactly as a machine's containerd does with the same registry.
//
// Asked with a HEAD before pulling, so a registry that is not running costs a
// refused connection on loopback rather than the framework's three retries a
// second apart.

import Containerization
import ContainerizationOCI
import Foundation

enum ImageMirror {
    /// host:port of this Mac's registry, from --image-mirror. Nil turns this off.
    static let address: String? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--image-mirror"), i + 1 < args.count,
              !args[i + 1].isEmpty else { return nil }
        return args[i + 1]
    }()

    /// docker.io/library/app:dev -> ("docker.io/library/app", "dev").
    static func split(_ canonical: String) -> (repository: String, reference: String) {
        if let at = canonical.lastIndex(of: "@") {
            return (String(canonical[..<at]), String(canonical[canonical.index(after: at)...]))
        }
        if let colon = canonical.lastIndex(of: ":"),
           canonical[colon...].contains("/") == false {
            return (String(canonical[..<colon]), String(canonical[canonical.index(after: colon)...]))
        }
        return (canonical, "latest")
    }

    /// Whether the registry has the image, asked without pulling anything.
    /// The registry resolves the name against the other Macs here if it has
    /// to, so this can take a round trip to one of them.
    static func has(_ canonical: String, at address: String) async -> Bool {
        let (repository, reference) = split(canonical)
        guard let url = URL(string: "http://\(address)/v2/\(repository)/manifests/\(reference)") else {
            return false
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        request.setValue([
            "application/vnd.oci.image.index.v1+json",
            "application/vnd.oci.image.manifest.v1+json",
            "application/vnd.docker.distribution.manifest.list.v2+json",
            "application/vnd.docker.distribution.manifest.v2+json",
        ].joined(separator: ", "), forHTTPHeaderField: "Accept")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    /// Pulls the image from this Mac's registry and stores it under its own
    /// name, or returns nil so the caller goes to the real registry.
    static func pull(_ canonical: String, platform: ContainerizationOCI.Platform,
                     into store: ImageStore) async -> Containerization.Image? {
        guard let address else { return nil }
        let started = Date()
        guard await has(canonical, at: address) else { return nil }
        let mirrored = "\(address)/\(canonical)"
        do {
            _ = try await store.pull(reference: mirrored, platform: platform, insecure: true)
            let image = try await store.tag(existing: mirrored, new: canonical)
            try? await store.delete(reference: mirrored, performCleanup: false)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            print("    image     \(canonical) from this Mac's registry in \(ms)ms")
            return image
        } catch {
            print("    image     \(canonical): this Mac's registry failed (\(error)); trying upstream")
            return nil
        }
    }
}
