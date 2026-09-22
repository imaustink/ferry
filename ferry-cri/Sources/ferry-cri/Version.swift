// Which ferry this is, as the node reports it.
//
// The runtime version is what `kubectl get nodes -o wide` shows as
// CONTAINER-RUNTIME, and it was the literal "0.1.0" -- so a v0.3.0 install
// reported itself as ferry://0.1.0, and a bug report could not say which build
// it came from. Nothing in the binary knows its own release: a release is cut
// by packaging, not by compiling, so the version has to be read at run time.

import Foundation

enum FerryVersion {
    /// The environment variable the launcher sets. Wins over everything else,
    /// because the launcher is what knows which release it belongs to.
    static let environmentKey = "FERRY_VERSION"

    /// The release's own version, without a leading "v", or "dev" for a build
    /// from a checkout.
    ///
    /// In order: FERRY_VERSION; then a VERSION file beside the binary or one
    /// level up, which is the release layout -- bin/ferry-cri with VERSION at
    /// the top, read the same way `ferry` reads it, from its `ferry=` line.
    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let given = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !given.isEmpty {
            return normalize(given)
        }
        for candidate in versionFiles() {
            guard let text = try? String(contentsOf: candidate, encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("ferry=") {
                let value = line.dropFirst("ferry=".count).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return normalize(value) }
            }
        }
        return "dev"
    }

    /// CRI runtime versions are conventionally bare semver -- containerd
    /// reports 1.7.2, not v1.7.2 -- and this one used to be too.
    private static func normalize(_ version: String) -> String {
        version.hasPrefix("v") ? String(version.dropFirst()) : version
    }

    private static func versionFiles() -> [URL] {
        // Symlinks resolved, so a binary linked onto PATH still finds the
        // release it lives in rather than the directory holding the link.
        guard let binary = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return [] }
        let dir = binary.deletingLastPathComponent()
        return [dir.appending(component: "VERSION"),
                dir.deletingLastPathComponent().appending(component: "VERSION")]
    }
}
