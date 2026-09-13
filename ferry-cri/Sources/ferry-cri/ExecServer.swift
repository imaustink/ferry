// The pod-side half of `kubectl exec`.
//
// ferry-streamer owns the SPDY conversation with the kubelet, because that
// protocol is dead, fiddly, and Kubernetes already ships a correct server for
// it in Go. What it cannot do is reach into a pod's virtual machine, so it
// hands each request here over a unix socket and this runs the command.
//
// The link is framed: [1 byte channel][4 bytes big-endian length][payload],
// with channels for stdin, stdout, stderr, exit status and terminal resize.
// Both ends speak it; see ferry-streamer/frame.go.

import Containerization
import Foundation

enum ExecChannel: UInt8 {
    case stdin = 0
    case stdout = 1
    case stderr = 2
    case exit = 3
    case resize = 4
}

struct ExecHeader: Decodable {
    let containerID: String
    var cmd: [String]?
    var tty: Bool?
    var stdin: Bool?
}

/// Writes framed data to a socket. One instance per stream, sharing the
/// descriptor, so writes are serialised through a shared lock.
final class FrameWriter: Writer, @unchecked Sendable {
    private let socket: FrameSocket
    private let channel: ExecChannel

    init(socket: FrameSocket, channel: ExecChannel) {
        self.socket = socket
        self.channel = channel
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        socket.writeFrame(channel, data)
    }

    func close() throws {}
}

/// Feeds a process's stdin from frames arriving on the socket.
final class FrameReaderStream: ReaderStream, @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    private let underlying: AsyncStream<Data>

    init() {
        var captured: AsyncStream<Data>.Continuation!
        underlying = AsyncStream<Data> { captured = $0 }
        continuation = captured
    }

    func stream() -> AsyncStream<Data> { underlying }
    func deliver(_ data: Data) { continuation.yield(data) }
    func finish() { continuation.finish() }
}

/// A connection to ferry-streamer, with framed reads and writes.
final class FrameSocket: @unchecked Sendable {
    let descriptor: Int32
    private let writeLock = NSLock()

    init(descriptor: Int32) { self.descriptor = descriptor }

    func writeFrame(_ channel: ExecChannel, _ payload: Data) {
        writeLock.lock()
        defer { writeLock.unlock() }
        var header = Data([channel.rawValue])
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }
        writeAll(header)
        if !payload.isEmpty { writeAll(payload) }
    }

    private func writeAll(_ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }

    /// Reads exactly `count` bytes, or returns nil if the peer went away.
    private func readExactly(_ count: Int) -> Data? {
        guard count > 0 else { return Data() }
        var buffer = Data(count: count)
        var offset = 0
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            while offset < count {
                let got = Darwin.read(descriptor, raw.baseAddress!.advanced(by: offset), count - offset)
                if got <= 0 { return false }
                offset += got
            }
            return true
        }
        return ok ? buffer : nil
    }

    func readFrame() -> (ExecChannel, Data)? {
        guard let header = readExactly(5), let channel = ExecChannel(rawValue: header[0]) else { return nil }
        let length = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 1, as: UInt32.self).bigEndian }
        guard length <= 1 << 20 else { return nil }
        guard let payload = readExactly(Int(length)) else { return nil }
        return (channel, payload)
    }

    /// Reads the newline-terminated JSON header that opens every connection.
    func readHeaderLine() -> Data? {
        var line = Data()
        var byte: UInt8 = 0
        while line.count < 64 * 1024 {
            let got = Darwin.read(descriptor, &byte, 1)
            if got <= 0 { return nil }
            if byte == 0x0A { return line }
            line.append(byte)
        }
        return nil
    }

    func close() { Darwin.close(descriptor) }
}

/// Accepts exec requests from ferry-streamer.
final class ExecServer: @unchecked Sendable {
    private let path: String
    private let runtime: PodRuntime

    init(path: String, runtime: PodRuntime) {
        self.path = path
        self.runtime = runtime
    }

    func start() throws {
        unlink(path)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw RuntimeFailure.unsupported("could not create exec socket") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            // macOS caps unix socket paths near 104 bytes.
            throw RuntimeFailure.invalid("exec socket path is too long: \(path)")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { dst in
                for (i, byte) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: byte) }
                dst[pathBytes.count] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, size) }
        }
        guard bound == 0, listen(listener, 16) == 0 else {
            Darwin.close(listener)
            throw RuntimeFailure.unsupported("could not listen on \(path)")
        }

        let runtime = self.runtime
        Thread.detachNewThread {
            while true {
                let accepted = accept(listener, nil, nil)
                if accepted < 0 { continue }
                let socket = FrameSocket(descriptor: accepted)
                Task { await Self.handle(socket: socket, runtime: runtime) }
            }
        }
    }

    private static func handle(socket: FrameSocket, runtime: PodRuntime) async {
        defer { socket.close() }
        guard let line = socket.readHeaderLine(),
              let header = try? JSONDecoder().decode(ExecHeader.self, from: line)
        else { return }

        let stdinStream = (header.stdin ?? false) ? FrameReaderStream() : nil
        do {
            let process = try await runtime.exec(
                containerID: header.containerID,
                command: header.cmd ?? [],
                tty: header.tty ?? false,
                stdin: stdinStream,
                stdout: FrameWriter(socket: socket, channel: .stdout),
                stderr: FrameWriter(socket: socket, channel: .stderr)
            )
            try await process.start()

            // Frames arriving while the command runs: input and window size.
            let pump = Task.detached {
                while let (channel, payload) = socket.readFrame() {
                    switch channel {
                    case .stdin:
                        if payload.isEmpty {
                            stdinStream?.finish()
                            try? await process.closeStdin()
                        } else {
                            stdinStream?.deliver(payload)
                        }
                    case .resize:
                        if let size = try? JSONDecoder().decode([String: UInt16].self, from: payload),
                           let width = size["width"], let height = size["height"] {
                            try? await process.resize(to: .init(width: width, height: height))
                        }
                    default:
                        continue
                    }
                }
                stdinStream?.finish()
            }

            let status = try await process.wait()
            pump.cancel()
            socket.writeFrame(.exit, Data([UInt8(clamping: Int(status.exitCode))]))
        } catch {
            let message = "ferry-cri: \(error)\n"
            socket.writeFrame(.stderr, Data(message.utf8))
            socket.writeFrame(.exit, Data([1]))
        }
    }
}
