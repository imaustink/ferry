// A small HTTP/1.1 server over unix domain sockets.
//
// Hand-rolled rather than pulled in, because the surface is tiny and the
// clients are known: ferry-cri, and whatever a pod runs. It speaks the subset
// those need -- a request line, headers, a Content-Length body, keep-alive --
// and says so plainly when asked for anything else. Chunked request bodies are
// rejected rather than half-supported.
//
// Blocking, thread per connection. The work behind these sockets is GPU work
// serialized on one device, so an event loop would buy nothing.

import Foundation

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    /// Path split on "/", empty components dropped: "/pods/abc" -> ["pods", "abc"].
    var segments: [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    func json<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: body)
    }
}

struct HTTPResponse {
    var status: Int
    var headers: [String: String] = [:]
    var body: Data = Data()

    static func json(_ value: some Encodable, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let body = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status,
                            headers: ["Content-Type": "application/json"],
                            body: body + Data("\n".utf8))
    }

    static func error(_ message: String, status: Int) -> HTTPResponse {
        json(["error": message], status: status)
    }

    static let reasons: [Int: String] = [
        200: "OK", 201: "Created", 204: "No Content", 400: "Bad Request",
        404: "Not Found", 405: "Method Not Allowed", 409: "Conflict",
        413: "Payload Too Large", 500: "Internal Server Error",
        501: "Not Implemented", 503: "Service Unavailable",
    ]
}

struct HTTPFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Whether a unix socket at this path has a live listener behind it, as opposed
/// to being a file a dead process left there.
func isListening(_ path: String) -> Bool {
    guard FileManager.default.fileExists(atPath: path) else { return false }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { Darwin.close(fd) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
    withUnsafeMutablePointer(to: &address.sun_path) { raw in
        raw.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { dst in
            for (i, byte) in bytes.enumerated() { dst[i] = CChar(bitPattern: byte) }
            dst[bytes.count] = 0
        }
    }
    var limit = timeval(tv_sec: 1, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) == 0 }
    }
}

/// Serves one unix socket. `identity` is carried to the handler untouched: it
/// is how a per-pod socket tells the router which pod is calling, and the
/// reason the relay is worth using at all.
final class UnixHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest, String?) -> HTTPResponse

    let path: String
    let identity: String?
    private let handler: Handler
    private let maxBody = 8 * 1024 * 1024
    /// Thread per connection is fine for work that is serialized on one GPU
    /// anyway, but it means a client that opens connections and never closes
    /// them costs a thread each. Past this, new connections are dropped rather
    /// than queued: the pod holding them is already misbehaving.
    private let maxConnections = 64
    /// Closes a connection that opens and then says nothing, and ends an idle
    /// keep-alive. Generous, because the legitimate pause is a client thinking
    /// between requests, not a slow request -- a slow request is the server
    /// writing, which this does not bound.
    private static let idleTimeout = timeval(tv_sec: 300, tv_usec: 0)
    private var listener: Int32 = -1
    private let closed = NSLock()
    private var isClosed = false
    private let connections = NSLock()
    private var openConnections = 0

    init(path: String, identity: String? = nil, handler: @escaping Handler) {
        self.path = path
        self.identity = identity
        self.handler = handler
    }

    func start() throws {
        // 0700: the sockets in here are the GPU. Anything that can open one has
        // already been granted it, so the only gate that matters is who can
        // reach the file -- and on a shared Mac that should not be every local
        // account.
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        chmod(directory, 0o700)

        // Unlinking whatever is at the path is how a stale socket from a crashed
        // instance gets cleared -- but done blindly it also lets a second daemon
        // quietly steal the first one's socket, after which half the pods talk
        // to one process and half to the other. So ask first: something that
        // accepts a connection is alive and this is not our path to take.
        if isListening(path) {
            throw HTTPFailure("something is already listening on \(path)")
        }
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HTTPFailure("socket(\(path)): \(errno)") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        // macOS caps sun_path near 104 bytes. A pod UID in a long state
        // directory gets close, so this is a real limit, not a formality.
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw HTTPFailure("socket path is too long (\(bytes.count) bytes): \(path)")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { dst in
                for (i, byte) in bytes.enumerated() { dst[i] = CChar(bitPattern: byte) }
                dst[bytes.count] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else {
            Darwin.close(fd)
            throw HTTPFailure("bind(\(path)): \(String(cString: strerror(errno)))")
        }
        guard listen(fd, 64) == 0 else {
            Darwin.close(fd)
            throw HTTPFailure("listen(\(path)): \(String(cString: strerror(errno)))")
        }

        // The other end of this socket is ferry-cri's relay, running as the same
        // user, so nothing else needs to open it. The pod reaches it through the
        // relay, not through this file.
        chmod(path, 0o600)
        listener = fd

        Thread.detachNewThread { [self] in
            while true {
                let accepted = accept(fd, nil, nil)
                if accepted < 0 {
                    if closed.withLock({ isClosed }) { return }
                    continue
                }
                let admitted = connections.withLock { () -> Bool in
                    guard openConnections < maxConnections else { return false }
                    openConnections += 1
                    return true
                }
                guard admitted else {
                    log("dropping a connection on \(path): \(maxConnections) already open")
                    Darwin.close(accepted)
                    continue
                }
                var limit = Self.idleTimeout
                setsockopt(accepted, SOL_SOCKET, SO_RCVTIMEO, &limit,
                           socklen_t(MemoryLayout<timeval>.size))
                Thread.detachNewThread { [self] in
                    defer { connections.withLock { openConnections -= 1 } }
                    serve(accepted)
                }
            }
        }
    }

    func stop() {
        closed.withLock { isClosed = true }
        if listener >= 0 { Darwin.close(listener); listener = -1 }
        unlink(path)
    }

    private func serve(_ fd: Int32) {
        defer { Darwin.close(fd) }
        var pending = Data()
        while true {
            let request: HTTPRequest?
            do {
                request = try read(fd, pending: &pending)
            } catch {
                send(fd, .error("\(error)", status: 400), keepAlive: false)
                return
            }
            guard let request else { return }  // client hung up

            let response = handler(request, identity)
            let keepAlive = request.headers["connection"]?.lowercased() != "close"
            send(fd, response, keepAlive: keepAlive)
            if !keepAlive { return }
        }
    }

    /// Reads one request, leaving anything already buffered beyond it in
    /// `pending` for the next call. Returns nil when the peer closed cleanly.
    private func read(_ descriptor: Int32, pending: inout Data) throws -> HTTPRequest? {
        let terminator = Data("\r\n\r\n".utf8)
        var head: Data
        while true {
            if let range = pending.range(of: terminator) {
                head = pending.subdata(in: pending.startIndex..<range.lowerBound)
                pending = pending.subdata(in: range.upperBound..<pending.endIndex)
                break
            }
            guard let chunk = readSome(descriptor) else {
                if pending.isEmpty { return nil }
                throw HTTPFailure("connection closed mid-request")
            }
            pending.append(chunk)
            if pending.count > maxBody { throw HTTPFailure("request head is too large") }
        }

        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw HTTPFailure("empty request") }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { throw HTTPFailure("malformed request line") }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        if let encoding = headers["transfer-encoding"], encoding.lowercased().contains("chunked") {
            throw HTTPFailure("chunked request bodies are not supported; send Content-Length")
        }

        var path = String(parts[1])
        var query: [String: String] = [:]
        if let mark = path.firstIndex(of: "?") {
            let raw = String(path[path.index(after: mark)...])
            path = String(path[path.startIndex..<mark])
            for pair in raw.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard let key = kv.first else { continue }
                query[String(key)] = kv.count > 1 ? String(kv[1]).removingPercentEncoding ?? String(kv[1]) : ""
            }
        }

        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length <= maxBody else { throw HTTPFailure("body exceeds \(maxBody) bytes") }
        while pending.count < length {
            guard let chunk = readSome(descriptor) else { throw HTTPFailure("connection closed mid-body") }
            pending.append(chunk)
        }
        let body = pending.prefix(length)
        pending = pending.dropFirst(length)

        return HTTPRequest(method: String(parts[0]).uppercased(), path: path,
                           query: query, headers: headers, body: Data(body))
    }

    private func readSome(_ descriptor: Int32) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        guard count > 0 else { return nil }
        return Data(buffer[0..<count])
    }

    private func send(_ descriptor: Int32, _ response: HTTPResponse, keepAlive: Bool) {
        let reason = HTTPResponse.reasons[response.status] ?? "Unknown"
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n"
        for (name, value) in response.headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"

        var out = Data(head.utf8)
        out.append(response.body)
        out.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                if written <= 0 { return }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
        }
    }
}
