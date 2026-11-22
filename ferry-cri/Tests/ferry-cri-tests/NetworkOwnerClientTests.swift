// ferry-cri's half of the ferry-netd protocol, against a stand-in server on a
// Unix socket: the reply is read, and a kept connection reports the server
// going away -- which is how ferry-cri learns its pod network has gone.

import Darwin
import Foundation
import Testing
@testable import ferry_cri

/// A value shared with a thread, read and written under a lock.
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    var get: Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: Value) { lock.lock(); value = new; lock.unlock() }
}

@Suite struct NetworkOwnerClientTests {
    /// Listens on a fresh socket, answers one request with `reply`, and holds
    /// the connection until `hangUp` is signalled.
    final class FakeOwner: @unchecked Sendable {
        let path = "/tmp/ferry-netd-test-\(UUID().uuidString.prefix(8)).sock"
        let hangUp = DispatchSemaphore(value: 0)
        let request = Box("")
        private let listener: Int32

        init(reply: String) throws {
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, listen(listener, 1) == 0 else { throw POSIXError(.EADDRINUSE) }
            let (listener, hangUp, request) = (self.listener, self.hangUp, self.request)
            Thread.detachNewThread {
                let client = accept(listener, nil, nil)
                var line = [UInt8](), byte: UInt8 = 0
                while read(client, &byte, 1) == 1, byte != UInt8(ascii: "\n") { line.append(byte) }
                request.set(String(decoding: line, as: UTF8.self))
                let out = Array((reply + "\n").utf8)
                _ = out.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                hangUp.wait()
                close(client)
            }
        }

        deinit { close(listener); unlink(path) }
    }

    @Test func aReplyIsReadAndTheConnectionClosedUnlessKept() throws {
        let owner = try FakeOwner(reply: "refused 1001")
        defer { owner.hangUp.signal() }
        let result = try #require(NetworkOwnerClient.ask(owner.path, "network 10.244.0.1/24"))
        #expect(result.reply == "refused 1001")
        #expect(result.connection == nil)
        #expect(owner.request.get == "network 10.244.0.1/24")
    }

    @Test func aKeptConnectionReportsTheOwnerGoingAway() async throws {
        let owner = try FakeOwner(reply: "ok AAAA")
        let result = try #require(NetworkOwnerClient.ask(owner.path, "network 10.244.0.1/24", keep: true))
        #expect(result.reply == "ok AAAA")
        let connection = try #require(result.connection)
        defer { close(connection) }

        let lost = Box(false)
        NetworkOwnerClient.watch(connection) { lost.set(true) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(lost.get == false)   // held: nothing reported

        owner.hangUp.signal()   // the owner exits
        for _ in 0..<50 where !lost.get {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(lost.get)
    }

    @Test func noOwnerIsNil() {
        #expect(NetworkOwnerClient.ask("/tmp/ferry-netd-nobody-\(UUID()).sock", "network 10.0.0.1/24") == nil)
    }
}
