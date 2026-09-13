// Container logs, in the format the kubelet parses.
//
// There is no CRI call for reading logs: the runtime writes them to the path
// the kubelet chose, and the kubelet reads that file directly when someone runs
// `kubectl logs`. Every line must be
//
//     <RFC3339Nano timestamp> <stdout|stderr> <F|P> <content>
//
// where the tag is F for a complete line and P for a fragment whose line
// continues in the next entry. Getting this wrong does not fail loudly -- the
// kubelet simply returns nothing, or returns mangled output -- so the format is
// worth being exact about.
//
// stdout and stderr share one file, so they must also share one file handle and
// one lock. Two handles on the same path keep independent seek positions and
// interleave into corruption.

import Containerization
import Foundation

enum LogStream: String {
    case stdout
    case stderr
}

/// A live subscriber to a container's output, used by `kubectl attach`.
protocol OutputSink: AnyObject, Sendable {
    func receive(_ data: Data, stream: LogStream)
}

/// The log file for one container, and the fan-out point for attach.
///
/// Attaching means reconnecting to a process that is already running, which the
/// framework has no way to do -- its stdio was bound when the container was
/// created and cannot be re-opened. But that stdio is bound to *this*, so
/// attach does not need the framework's help: it subscribes here and receives
/// the same bytes the log does, as they are written.
final class ContainerLogFile: @unchecked Sendable {
    private var sinks: [ObjectIdentifier: any OutputSink] = [:]
    private let sinkLock = NSLock()

    func subscribe(_ sink: any OutputSink) {
        sinkLock.lock(); defer { sinkLock.unlock() }
        sinks[ObjectIdentifier(sink)] = sink
    }

    func unsubscribe(_ sink: any OutputSink) {
        sinkLock.lock(); defer { sinkLock.unlock() }
        sinks.removeValue(forKey: ObjectIdentifier(sink))
    }

    /// Raw bytes, exactly as the process wrote them. Attach is a byte stream,
    /// not the timestamped line format the kubelet reads from the log file.
    func broadcast(_ data: Data, stream: LogStream) {
        sinkLock.lock()
        let current = Array(sinks.values)
        sinkLock.unlock()
        for sink in current { sink.receive(data, stream: stream) }
    }

    private let path: String
    private let lock = NSLock()
    private var handle: FileHandle?
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(path: String) throws {
        self.path = path
        try Self.ensureFile(at: path)
        self.handle = FileHandle(forWritingAtPath: path)
        try self.handle?.seekToEnd()
    }

    private static func ensureFile(at path: String) throws {
        let url = URL(filePath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
    }

    func append(_ content: Data, stream: LogStream, tag: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return }
        var line = Data()
        line.append("\(formatter.string(from: Date())) \(stream.rawValue) \(tag) ".data(using: .utf8)!)
        line.append(content)
        line.append(0x0A)
        try? handle.write(contentsOf: line)
    }

    /// Reopen after the kubelet rotates the file. Without this the runtime keeps
    /// writing into the rotated file through its open descriptor and
    /// `kubectl logs` goes quiet.
    func reopen() throws {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        try Self.ensureFile(at: path)
        handle = FileHandle(forWritingAtPath: path)
        try handle?.seekToEnd()
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }
}

/// One stream's view of a container's log file. Partial-line buffering is per
/// stream, because stdout and stderr fragment independently.
final class ContainerLogWriter: Writer, @unchecked Sendable {
    private let file: ContainerLogFile
    private let stream: LogStream
    private let lock = NSLock()
    private var pending = Data()

    init(file: ContainerLogFile, stream: LogStream) {
        self.file = file
        self.stream = stream
    }

    func write(_ data: Data) throws {
        // Anyone attached sees the bytes as written, before they are split into
        // lines and timestamped for the log file.
        file.broadcast(data, stream: stream)

        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = Data(pending[pending.startIndex..<newline])
            pending = pending[pending.index(after: newline)...]
            file.append(line, stream: stream, tag: "F")
        }
        // A very long line with no newline would otherwise buffer without
        // bound; emit it as a fragment.
        if pending.count > 16 * 1024 {
            file.append(pending, stream: stream, tag: "P")
            pending = Data()
        }
    }

    /// Flush a trailing line that never got its newline.
    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        if !pending.isEmpty {
            file.append(pending, stream: stream, tag: "F")
            pending = Data()
        }
    }
}
