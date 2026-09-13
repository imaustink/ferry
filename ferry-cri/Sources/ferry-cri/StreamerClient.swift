// Asks ferry-streamer for a streaming URL.
//
// The token in that URL comes from the streaming server's own request cache, so
// only it can issue one -- ferry-cri cannot invent a URL and have the kubelet's
// connection be accepted. This is a small HTTP client over a unix socket; the
// exchange is one short request and one short response, so it is written
// directly rather than pulling in a client stack.

import Foundation

struct StreamerClient: Sendable {
    let socketPath: String

    enum Failure: Error, CustomStringConvertible {
        case unreachable(String)
        case rejected(String)

        var description: String {
            switch self {
            case .unreachable(let m): "ferry-streamer is unreachable: \(m)"
            case .rejected(let m): "ferry-streamer rejected the request: \(m)"
            }
        }
    }

    func url(path: String, body: [String: Any]) throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: body)
        let response = try exchange(path: path, payload: payload).body
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let url = object["url"] as? String, !url.isEmpty
        else {
            throw Failure.rejected(String(data: response, encoding: .utf8) ?? "unreadable response")
        }
        return url
    }

    func exchangeGet(path: String) throws -> Data {
        try exchange(path: path, payload: nil, method: "GET").body
    }

    private func exchange(path: String, payload: Data?, method: String = "POST",
                          timeout: TimeInterval = 30) throws -> (body: Data, headers: [String: String]) {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.unreachable("socket() failed") }
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw Failure.unreachable("socket path is too long")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { dst in
                for (i, byte) in bytes.enumerated() { dst[i] = CChar(bitPattern: byte) }
                dst[bytes.count] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, size) }
        }
        guard ok == 0 else { throw Failure.unreachable("connect(\(socketPath)) failed") }

        // A read timeout, so a wedged peer cannot park this task forever. It has
        // to outlast a long poll, which is answered by the server well before it.
        var limit = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))

        var request = "\(method) \(path) HTTP/1.0\r\nHost: ferry\r\nContent-Type: application/json\r\n"
        request += "Content-Length: \(payload?.count ?? 0)\r\nConnection: close\r\n\r\n"
        var outgoing = Data(request.utf8)
        if let payload { outgoing.append(payload) }
        try writeAll(descriptor, outgoing)

        var incoming = Data()
        var buffer = [UInt8](repeating: 0, count: 8 * 1024)
        while true {
            let got = read(descriptor, &buffer, buffer.count)
            if got <= 0 { break }
            incoming.append(contentsOf: buffer[0..<got])
        }

        // Split off the status line and headers; the body is the JSON we want.
        guard let separator = incoming.range(of: Data("\r\n\r\n".utf8)) else {
            throw Failure.rejected("malformed response")
        }
        let head = String(data: incoming[..<separator.lowerBound], encoding: .utf8) ?? ""
        let lines = head.components(separatedBy: "\r\n")
        guard head.contains(" 200 ") else {
            throw Failure.rejected(lines.first ?? "no status")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return (Data(incoming[separator.upperBound...]), headers)
    }

    private func writeAll(_ descriptor: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard written > 0 else { throw Failure.unreachable("short write") }
                offset += written
            }
        }
    }
}

struct PodContainers: Decodable {
    let initContainers: [String]?
    let containers: [String]?
}

extension StreamerClient {
    /// A plain GET against ferry-streamer's control socket.
    func get(path: String) throws -> Data {
        try exchangeGet(path: path)
    }

    /// A ruleset and the generation it was rendered at.
    struct Ruleset {
        let body: Data
        let generation: UInt64
    }

    /// Fetches the Service ruleset. Naming a generation asks ferry-proxyd to
    /// hold the request open until it has something newer, so a change reaches
    /// the pods when it is rendered rather than on the next turn of a poll. The
    /// server lets go by itself well before the timeout here.
    func ruleset(after generation: UInt64? = nil) throws -> Ruleset {
        var path = "/ruleset"
        if let generation { path += "?after=\(generation)" }
        let response = try exchange(path: path, payload: nil, method: "GET", timeout: 45)
        return Ruleset(body: response.body,
                       generation: UInt64(response.headers["x-ferry-generation"] ?? "") ?? 0)
    }
}
