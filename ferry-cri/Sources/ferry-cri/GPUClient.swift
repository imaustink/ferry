// Asks ferry-gpud for a socket on a pod's behalf.
//
// The Mac's GPU is reachable only through Metal, in a macOS process, so a pod
// that wants it is given a unix socket rather than a device: ferry-gpud binds
// one per pod, and Containerization relays it into the VM over vsock. See
// docs/GPU.md and experiments/08-vsock-socket-relay.
//
// Small and synchronous on purpose. This runs on the CreateContainer path,
// where the alternative to a blocking call is a container that starts before
// its socket exists.

import Foundation

struct GPUGrant: Decodable {
    let uid: String
    let socket: String
}

/// A client for ferry-gpud's control socket. Absent daemon, absent GPU: every
/// call fails in a way the caller can report, and no pod is held up for a
/// resource the node should not have advertised in the first place.
struct GPUClient: Sendable {
    let controlSocket: String

    /// Where the pod's socket appears inside its VM. A fixed path, because the
    /// pod has exactly one and nothing else may be at it.
    static let guestPath = "/run/ferry/gpu.sock"

    func grant(uid: String, namespace: String, name: String) throws -> GPUGrant {
        let body = try JSONEncoder().encode(
            ["uid": uid, "namespace": namespace, "name": name])
        let response = try exchange(method: "POST", path: "/pods", body: body)
        return try JSONDecoder().decode(GPUGrant.self, from: response)
    }

    /// Best effort: a pod going away must not fail because the GPU daemon did.
    func revoke(uid: String) {
        _ = try? exchange(method: "DELETE", path: "/pods/\(uid)", body: nil)
    }

    /// Bounds how long a CreateContainer can be held up by the GPU daemon.
    ///
    /// This matters more than it looks: PodRuntime is an actor, and these calls
    /// are synchronous, so a ferry-gpud that accepts a connection and then
    /// wedges would block the actor's thread and stall every other CRI call on
    /// the node. The daemon is a local process doing a local bind, so anything
    /// beyond a couple of seconds is already a failure.
    private static let timeout = timeval(tv_sec: 3, tv_usec: 0)

    private func exchange(method: String, path: String, body: Data?) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RuntimeFailure.unsupported("could not open a socket") }
        defer { Darwin.close(fd) }

        var limit = Self.timeout
        let limitSize = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, limitSize)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, limitSize)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(controlSocket.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw RuntimeFailure.invalid("gpud socket path is too long: \(controlSocket)")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { dst in
                for (i, byte) in bytes.enumerated() { dst[i] = CChar(bitPattern: byte) }
                dst[bytes.count] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard connected == 0 else {
            throw RuntimeFailure.unsupported("ferry-gpud is not listening on \(controlSocket)")
        }

        var request = "\(method) \(path) HTTP/1.1\r\nHost: gpud\r\nConnection: close\r\n"
        request += "Content-Length: \(body?.count ?? 0)\r\n"
        if body != nil { request += "Content-Type: application/json\r\n" }
        request += "\r\n"
        var out = Data(request.utf8)
        if let body { out.append(body) }
        try write(fd, out)

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { break }  // the daemon closed, which is how it ends
            if count < 0 {
                guard errno == EAGAIN || errno == EWOULDBLOCK else {
                    throw RuntimeFailure.unsupported("ferry-gpud: \(String(cString: strerror(errno)))")
                }
                throw RuntimeFailure.unsupported(
                    "ferry-gpud did not answer within \(Self.timeout.tv_sec)s")
            }
            received.append(contentsOf: buffer[0..<count])
        }

        guard let separator = received.range(of: Data("\r\n\r\n".utf8)) else {
            throw RuntimeFailure.invalid("ferry-gpud returned a malformed response")
        }
        let head = String(decoding: received[received.startIndex..<separator.lowerBound], as: UTF8.self)
        let payload = received.subdata(in: separator.upperBound..<received.endIndex)

        let status = head.components(separatedBy: "\r\n").first?
            .split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        guard (200..<300).contains(status) else {
            // The daemon's own message is more useful than the status: over
            // capacity reads very differently from a malformed uid.
            let detail = (try? JSONDecoder().decode([String: String].self, from: payload))?["error"]
            throw RuntimeFailure.unsupported("ferry-gpud: \(detail ?? "HTTP \(status)")")
        }
        return payload
    }

    private func write(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                guard written > 0 else { throw RuntimeFailure.unsupported("ferry-gpud closed the connection") }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
        }
    }
}
