// The kubelet's PING stream must not get its CRI connection closed
// (experiment 38). These speak raw HTTP/2 to a real gRPC server on a Unix
// socket, so they break if ferry-cri's limit stops reaching the server, and the
// control case proves the default limit really does close the connection.
//
// gRPC's ping policing is turned off here, and only here. It answers a third
// PING inside five minutes with GOAWAY "too_many_pings", but forgives every
// PING that follows data it sent. The kubelet's BDP PINGs only ever follow data,
// so in ferry they are never struck; a flood sent all at once has no data
// between its PINGs and would be. Turning it off leaves the control-frame limit
// as the only thing that can close the connection, which is what is under test.

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Testing
@testable import ferry_cri

@Suite struct CRITransportTests {
    /// Above the 200 a default server allows in any 10 seconds.
    static let pings = 1_000

    /// PING acks read back, and the GOAWAY that ended the connection, if one did.
    struct Flood {
        var acks: Int
        var goaway: (code: UInt32, debug: String)?
    }

    @Test func theKubeletsPingsAreAnswered() async throws {
        let result = try await flood(config: CRITransport.config)
        #expect(result.goaway == nil)
        #expect(result.acks == Self.pings)
    }

    @Test func theDefaultLimitClosesTheConnection() async throws {
        let result = try await flood(config: .defaults)
        // ENHANCE_YOUR_CALM from the flood limiter, not gRPC's ping policing.
        #expect(result.goaway?.code == 0xb)
        #expect(result.goaway?.debug != "too_many_pings")
        #expect(result.acks < Self.pings)
    }

    /// Serves `config` on a fresh socket, sends `pings` PINGs at once, and
    /// reads until every ack or a GOAWAY arrives.
    private func flood(config: HTTP2ServerTransport.Posix.Config) async throws -> Flood {
        var config = config
        config.connection.keepalive.clientBehavior = .init(minPingIntervalWithoutCalls: .zero, allowWithoutCalls: true)
        let path = "/tmp/ferry-cri-test-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let transport = HTTP2ServerTransport.Posix(
            address: .unixDomainSocket(path: path), transportSecurity: .plaintext, config: config)
        let server = GRPCServer(transport: transport, services: [])

        return try await withThrowingTaskGroup(of: Flood?.self) { group in
            group.addTask { try await server.serve(); return nil }
            _ = try await transport.listeningAddress
            group.addTask { try Self.pingFlood(path: path, count: Self.pings) }
            var result = Flood(acks: 0, goaway: nil)
            for try await value in group {
                if let value { result = value; break }
            }
            server.beginGracefulShutdown()
            group.cancelAll()
            return result
        }
    }

    private static func pingFlood(path: String, count: Int) throws -> Flood {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EBADF) }
        defer { close(fd) }
        // A server that closes on the flood would otherwise SIGPIPE the test run.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: Array(path.utf8) + [0])
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // Preface, an empty SETTINGS, then the PINGs, in one write.
        var out = Array("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
        out += frameHeader(length: 0, type: 0x4, flags: 0)
        for i in 0..<count {
            out += frameHeader(length: 8, type: 0x6, flags: 0)
            out += withUnsafeBytes(of: UInt64(i).bigEndian, Array.init)
        }
        var sent = 0
        while sent < out.count {
            let n = out[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }  // the server may close mid-write; what it said is still readable
            sent += n
        }

        // Frames back: count PING acks, stop at a GOAWAY or a closed socket.
        var buffer: [UInt8] = []
        var acks = 0
        var chunk = [UInt8](repeating: 0, count: 65536)
        while acks < count {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer += chunk[0..<n]
            while buffer.count >= 9 {
                let length = Int(buffer[0]) << 16 | Int(buffer[1]) << 8 | Int(buffer[2])
                guard buffer.count >= 9 + length else { break }
                let (type, flags) = (buffer[3], buffer[4])
                if type == 0x7, length >= 8 {
                    let code = buffer[13...16].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                    let debug = String(decoding: buffer[17..<(9 + length)], as: UTF8.self)
                    return Flood(acks: acks, goaway: (code, debug))
                }
                if type == 0x6 && flags & 0x1 != 0 { acks += 1 }
                buffer.removeFirst(9 + length)
            }
        }
        return Flood(acks: acks, goaway: nil)
    }

    private static func frameHeader(length: Int, type: UInt8, flags: UInt8) -> [UInt8] {
        [UInt8(length >> 16 & 0xff), UInt8(length >> 8 & 0xff), UInt8(length & 0xff), type, flags, 0, 0, 0, 0]
    }
}
