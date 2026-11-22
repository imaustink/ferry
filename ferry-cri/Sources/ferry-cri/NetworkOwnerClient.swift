// One request to ferry-netd: a line out, a line back. See ferry-netd/main.swift
// for the protocol and for why the network is held there.

import Darwin
import Foundation

enum NetworkOwnerClient {
    /// The reply line, or nil when ferry-netd cannot be reached or does not
    /// answer within `timeout` seconds. With `keep`, the connection is left
    /// open and returned, to be watched with `watch`; otherwise it is closed.
    static func ask(_ socketPath: String, _ request: String, timeout: Int = 10,
                    keep: Bool = false) -> (reply: String, connection: Int32?)? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var keepOpen = false
        defer { if !keepOpen { close(fd) } }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path + [0]) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        let out = Array((request + "\n").utf8)
        guard out.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == out.count else { return nil }

        // A byte at a time up to the newline, so nothing after it is consumed
        // from a connection that is about to be watched.
        var reply = [UInt8]()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            if byte == UInt8(ascii: "\n") {
                let line = String(decoding: reply, as: UTF8.self)
                guard keep else { return (line, nil) }
                keepOpen = true
                tv = timeval(tv_sec: 0, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                return (line, fd)
            }
            reply.append(byte)
        }
        return nil
    }

    /// Calls `lost` once if ferry-netd closes `connection`, which it does only
    /// by exiting. Nothing else is ever sent on it.
    static func watch(_ connection: Int32, lost: @escaping @Sendable () -> Void) {
        Thread.detachNewThread {
            var sink = [UInt8](repeating: 0, count: 64)
            while true {
                let n = read(connection, &sink, sink.count)
                if n > 0 { continue }
                if n < 0 && errno == EINTR { continue }
                break
            }
            lost()
        }
    }
}
