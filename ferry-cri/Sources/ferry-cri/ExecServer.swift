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
    /// "exec" runs a command; "podip" just reports a sandbox's address, which
    /// is all port forwarding needs -- pod IPs are routable from the Mac, so
    /// ferry-streamer dials the pod directly rather than piping through here.
    var op: String?
    var containerID: String?
    var sandboxID: String?
    var cmd: [String]?
    var tty: Bool?
    var stdin: Bool?
    /// "loadimage": an OCI layout directory to take images from.
    var path: String?
    /// The environment to run the command with. A CNI plugin needs one -- the
    /// verb and the container id travel in it -- and `kubectl exec` does not.
    var env: [String]?
    /// Extra capabilities, by name. Programming a pod's netfilter tables takes
    /// NET_ADMIN, which an ordinary pod does not ask for; granting it to a
    /// binary ferry ships and runs keeps the privilege off the workload.
    var caps: [String]?
}

/// Forwards a container's live output to an attached client.
final class AttachSink: OutputSink, @unchecked Sendable {
    private let socket: FrameSocket
    init(socket: FrameSocket) { self.socket = socket }

    func receive(_ data: Data, stream: LogStream) {
        socket.writeFrame(stream == .stderr ? .stderr : .stdout, data)
    }
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

    /// Reconnects a client to a container that is already running.
    ///
    /// The framework cannot re-open a running process's stdio, but it does not
    /// have to: output is already flowing through our own writer, so attaching
    /// is a subscription. Input works only if the pod asked for stdin, since a
    /// stream has to have been wired in when the container was created.
    private static func attach(containerID: String, socket: FrameSocket, runtime: PodRuntime) async {
        let targets: (output: ContainerLogFile, stdin: FrameReaderStream?, tty: Bool)
        do {
            targets = try await runtime.attachTargets(containerID)
        } catch {
            socket.writeFrame(.stderr, Data("ferry-cri: \(error)\n".utf8))
            socket.writeFrame(.exit, Data([1]))
            return
        }

        let sink = AttachSink(socket: socket)
        targets.output.subscribe(sink)
        defer { targets.output.unsubscribe(sink) }

        // Hold the connection open, forwarding anything the client types, until
        // it disconnects. Output arrives through the sink meanwhile.
        while let (channel, payload) = socket.readFrame() {
            switch channel {
            case .stdin:
                guard let feeder = targets.stdin else { continue }
                if payload.isEmpty { feeder.finish() } else { feeder.deliver(payload) }
            default:
                continue
            }
        }
    }

    private static func handle(socket: FrameSocket, runtime: PodRuntime) async {
        defer { socket.close() }
        guard let line = socket.readHeaderLine(),
              let header = try? JSONDecoder().decode(ExecHeader.self, from: line)
        else { return }

        // Loading an image has to happen in this process, because this process
        // owns the image store. The CLI unpacks an archive and points here.
        if header.op == "loadimage" {
            var reply: [String: Any] = [:]
            do {
                let loaded = try await runtime.loadImages(from: header.path ?? "")
                reply["images"] = loaded
            } catch {
                reply["error"] = "\(error)"
            }
            if let encoded = try? JSONSerialization.data(withJSONObject: reply) {
                var line = encoded
                line.append(0x0A)
                _ = line.withUnsafeBytes { Darwin.write(socket.descriptor, $0.baseAddress, $0.count) }
            }
            return
        }

        if header.op == "podip" {
            let ip = await runtime.sandboxAddress(header.sandboxID ?? "")
            let reply = ["ip": ip ?? ""]
            if let encoded = try? JSONSerialization.data(withJSONObject: reply) {
                var line = encoded
                line.append(0x0A)
                _ = line.withUnsafeBytes { Darwin.write(socket.descriptor, $0.baseAddress, $0.count) }
            }
            return
        }

        guard let containerID = header.containerID else { return }

        if header.op == "attach" {
            await attach(containerID: containerID, socket: socket, runtime: runtime)
            return
        }

        let stdinStream = (header.stdin ?? false) ? FrameReaderStream() : nil
        do {
            let process = try await runtime.exec(
                containerID: containerID,
                command: header.cmd ?? [],
                tty: header.tty ?? false,
                stdin: stdinStream,
                stdout: FrameWriter(socket: socket, channel: .stdout),
                stderr: FrameWriter(socket: socket, channel: .stderr),
                capabilities: header.caps.map { PodRuntime.capabilities(adding: $0) },
                environment: header.env
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

/// Delivers a fixed payload as a process's stdin, then closes it.
final class DataReaderStream: ReaderStream, @unchecked Sendable {
    private let payload: Data
    init(_ payload: Data) { self.payload = payload }

    func stream() -> AsyncStream<Data> {
        let payload = self.payload
        return AsyncStream { continuation in
            continuation.yield(payload)
            continuation.finish()
        }
    }
}

/// Swallows output from processes ferry runs for its own purposes.
final class DiscardWriter: Writer, @unchecked Sendable {
    func write(_ data: Data) throws {}
    func close() throws {}
}

/// Surfaces a helper process's stderr, so a failure to program Service rules
/// says why instead of disappearing.
final class ErrorWriter: Writer, @unchecked Sendable {
    private let prefix: String
    init(prefix: String) { self.prefix = prefix }

    func write(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        FileHandle.standardError.write(Data("\(prefix): \(text)".utf8))
    }

    func close() throws {}
}
