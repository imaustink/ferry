// A macOS VM as a pod sandbox, booted on the host by ferry-cri.
//
// Stage 2 of moving macOS pods off the provision-a-whole-Node path onto the host
// node, the way a Linux ferry-vm pod already gets a microVM sandbox here (see
// docs/design/macos-cri-sandbox.md). A darwin sandbox is a macOS guest cloned
// from the golden bundle, booted behind the hypervisor, driven over vsock by the
// guest agent (ferry-macagent, port 7000) -- no second kubelet, no node
// registration, no Karpenter round-trip.
//
// The VM lifecycle here is the proven one from ferry-macvm's build coprocess
// (clone -> boot -> exec over vsock -> stop), lifted into a class ferry-cri's
// PodRuntime actor can hold: the Virtualization types are non-Sendable and must
// only be touched on the VM's own queue, so they are encapsulated here and the
// class exposes async methods (via continuations) that pass only Sendable data
// across the actor boundary.
//
// What this module owns: cloning the bundle, booting the guest, the vsock exec
// protocol, and teardown. What it does not yet own -- assembling the container
// root from the image layers plus the guest's OS base (ferry-darwin's job),
// pod networking beyond NAT, and stats -- is the remaining Stage 2 work called
// out in the design doc. Every VM operation is verified only by compilation
// here; booting a macOS guest needs a golden image and Virtualization
// entitlements on real Mac hardware.

import Foundation
// Virtualization's callback types (VZVirtualMachine, VZVirtioSocketConnection)
// are non-Sendable; they are confined to this class's queue, so import it
// @preconcurrency to treat the framework's Sendable diagnostics as the warnings
// they are rather than errors -- the same confinement ferry-macvm relies on.
@preconcurrency import Virtualization

/// One exec request to the guest agent: argv, plus an optional environment,
/// working directory, and chroot. The exact shape agent.swift decodes.
struct DarwinRunRequest: Codable, Sendable {
    var argv: [String]
    var env: [String: String]?
    var cwd: String?
    var chroot: String?

    init(argv: [String], env: [String: String]? = nil, cwd: String? = nil, chroot: String? = nil) {
        self.argv = argv
        self.env = env
        self.cwd = cwd
        self.chroot = chroot
    }
}

/// The agent's response stream is a series of frames: `[type u8][len u32 BE][payload]`.
/// type 1 = stdout, 2 = stderr, 3 = exit (payload is a 4-byte BE int32), 4 = an
/// agent-side error. This is the wire format agent.swift writes and ferry-macvm
/// relays; kept as a pure decoder so it can be unit-tested without a guest.
enum DarwinFrameKind: UInt8 {
    case stdout = 1
    case stderr = 2
    case exit = 3
    case error = 4
}

struct DarwinFrame: Equatable {
    let kind: DarwinFrameKind
    let payload: [UInt8]
}

enum DarwinFrameError: Error, Equatable {
    case unknownKind(UInt8)
    case truncated
}

/// Incrementally parses frames out of a byte stream. Feed it whatever `read`
/// returns; it yields every complete frame and keeps the partial remainder for
/// the next feed. The parser is the load-bearing, hardware-independent part of
/// the guest protocol, so it is pure and tested (DarwinFrameTests).
struct DarwinFrameParser {
    private var buffer: [UInt8] = []

    mutating func feed(_ bytes: [UInt8]) throws -> [DarwinFrame] {
        buffer.append(contentsOf: bytes)
        var frames: [DarwinFrame] = []
        while true {
            guard buffer.count >= 5 else { break }
            let len = Int(UInt32(buffer[1]) << 24 | UInt32(buffer[2]) << 16
                | UInt32(buffer[3]) << 8 | UInt32(buffer[4]))
            guard buffer.count >= 5 + len else { break }
            guard let kind = DarwinFrameKind(rawValue: buffer[0]) else {
                throw DarwinFrameError.unknownKind(buffer[0])
            }
            let payload = Array(buffer[5 ..< 5 + len])
            frames.append(DarwinFrame(kind: kind, payload: payload))
            buffer.removeFirst(5 + len)
        }
        return frames
    }

    /// Nothing left half-read -- a clean stream ends on a frame boundary.
    var isDrained: Bool { buffer.isEmpty }

    /// Decodes an exit frame's 4-byte big-endian payload into a status code.
    static func exitStatus(_ payload: [UInt8]) -> Int32 {
        guard payload.count >= 4 else { return -1 }
        return Int32(bitPattern: UInt32(payload[0]) << 24 | UInt32(payload[1]) << 16
            | UInt32(payload[2]) << 8 | UInt32(payload[3]))
    }
}

/// The four files a macOS VM bundle is, so a clone is a clone of these.
struct DarwinBundle {
    let dir: URL
    var hardwareModel: URL { dir.appendingPathComponent("HardwareModel.bin") }
    var machineIdentifier: URL { dir.appendingPathComponent("MachineIdentifier.bin") }
    var auxiliary: URL { dir.appendingPathComponent("AuxiliaryStorage") }
    var disk: URL { dir.appendingPathComponent("Disk.img") }
}

/// Where the agent listens in the guest, matching agent.swift / ferry-macvm.
private let darwinAgentPort: UInt32 = 7000

/// A booted (or bootable) macOS sandbox guest.
///
/// `@unchecked Sendable` because every mutable field and every Virtualization
/// call is confined to `queue`; the async methods hop onto it and pass only
/// Sendable data back out through their continuations, so the actor that holds a
/// DarwinSandbox never touches a non-Sendable VZ object itself.
final class DarwinSandbox: @unchecked Sendable {
    let id: String
    let golden: DarwinBundle
    let workDir: URL
    let cpus: Int
    let memoryBytes: UInt64
    /// The pod's cluster NIC (en1 on the shared switch), when it has one. Added
    /// to the VM config alongside the NAT NIC; the guest brings it up by MAC.
    private let switchInterface: SwitchInterface?

    /// This guest's own serial queue -- Virtualization asserts every VM
    /// operation runs on the queue the VM was created with.
    private let queue: DispatchQueue
    private var vm: VZVirtualMachine?
    private var socket: VZVirtioSocketDevice?
    private var delegate: Delegate?
    /// Held connections: closing a vsock connection from inside its own open
    /// callback crashes the framework (ferry-macvm's note), so they live until
    /// the guest stops.
    private var connections: [VZVirtioSocketConnection] = []
    private var stopped = false

    init(id: String, golden: URL, workDir: URL, cpus: Int, memoryBytes: UInt64,
         switchInterface: SwitchInterface? = nil) {
        self.id = id
        self.golden = DarwinBundle(dir: golden)
        self.workDir = workDir
        self.cpus = max(1, cpus)
        self.memoryBytes = memoryBytes
        self.switchInterface = switchInterface
        self.queue = DispatchQueue(label: "ferry.darwin.sandbox.\(id)")
    }

    private final class Delegate: NSObject, VZVirtualMachineDelegate {
        var onStop: () -> Void = {}
        func guestDidStop(_ vm: VZVirtualMachine) { onStop() }
        func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) { onStop() }
    }

    /// A copy-on-write clone of the golden bundle: microseconds on APFS, and
    /// nothing can leak back into the golden image. A fresh machine identifier,
    /// because two guests must not share one.
    private func clone() throws -> DarwinBundle {
        try? FileManager.default.removeItem(at: workDir)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let clonedBundle = DarwinBundle(dir: workDir)
        for (s, d) in [(golden.disk, clonedBundle.disk),
                       (golden.auxiliary, clonedBundle.auxiliary),
                       (golden.hardwareModel, clonedBundle.hardwareModel)] {
            guard clonefile(s.path, d.path, 0) == 0 else {
                throw NSError(domain: "ferry.darwin.clonefile", code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: "clonefile \(s.path): \(String(cString: strerror(errno)))"])
            }
        }
        try VZMacMachineIdentifier().dataRepresentation.write(to: clonedBundle.machineIdentifier)
        return clonedBundle
    }

    private func configuration(_ b: DarwinBundle) throws -> VZVirtualMachineConfiguration {
        let platform = VZMacPlatformConfiguration()
        guard let hw = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: b.hardwareModel)),
              let mid = VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: b.machineIdentifier))
        else {
            throw NSError(domain: "ferry.darwin", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "unreadable bundle \(b.dir.path)"])
        }
        platform.hardwareModel = hw
        platform.machineIdentifier = mid
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: b.auxiliary)

        let c = VZVirtualMachineConfiguration()
        c.platform = platform
        c.bootLoader = VZMacOSBootLoader()
        c.cpuCount = cpus
        c.memorySize = memoryBytes
        let disk = try VZDiskImageStorageDeviceAttachment(url: b.disk, readOnly: false,
            cachingMode: .automatic, synchronizationMode: .full)
        c.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]
        // en0: NAT for the internet and the default route -- fast, free NAT and
        // gateway, the same role vmnet plays for a Linux pod's eth0.
        let nat = VZVirtioNetworkDeviceConfiguration()
        nat.attachment = VZNATNetworkDeviceAttachment()
        c.networkDevices = [nat]
        // en1: the pod's cluster NIC on ferry's shared L2 switch, carrying its
        // real cluster IP. The guest addresses it by the MAC we set here.
        if let switchInterface {
            c.networkDevices.append(try switchInterface.device())
        }
        c.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        try c.validate()
        return c
    }

    /// Clone the golden bundle, boot the guest, and resolve once the agent
    /// answers -- the point a container could first run.
    func boot() async throws {
        let clonedBundle = try clone()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let c = try self.configuration(clonedBundle)
                    let machine = VZVirtualMachine(configuration: c, queue: self.queue)
                    let d = Delegate()
                    d.onStop = { self.stopped = true }
                    machine.delegate = d
                    self.vm = machine
                    self.delegate = d
                    self.socket = machine.socketDevices.first as? VZVirtioSocketDevice
                    machine.start(options: VZMacOSVirtualMachineStartOptions()) { error in
                        if let error { cont.resume(throwing: error); return }
                        self.waitForAgent(cont)
                    }
                } catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Retry the agent port until it answers, then resolve. Runs on `queue`.
    private func waitForAgent(_ cont: CheckedContinuation<Void, Error>) {
        guard let dev = socket else {
            cont.resume(throwing: NSError(domain: "ferry.darwin", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "no vsock device"]))
            return
        }
        func attempt(_ tries: Int) {
            dev.connect(toPort: darwinAgentPort) { r in
                switch r {
                case .success(let conn):
                    self.queue.async {
                        self.connections.append(conn)
                        cont.resume()
                    }
                case .failure:
                    if tries <= 0 {
                        self.queue.async {
                            cont.resume(throwing: NSError(domain: "ferry.darwin", code: 3,
                                userInfo: [NSLocalizedDescriptionKey: "guest agent never answered"]))
                        }
                        return
                    }
                    self.queue.asyncAfter(deadline: .now() + 0.1) { attempt(tries - 1) }
                }
            }
        }
        attempt(600) // ~60s, the same ceiling ferry-node's boot uses
    }

    /// Run one command in the guest, streaming its stdout/stderr to `onOutput`
    /// as frames arrive, and returning its exit status. `onOutput` is
    /// @Sendable so the caller can funnel it into a thread-safe log sink.
    func run(_ req: DarwinRunRequest,
             onOutput: @escaping @Sendable (DarwinFrameKind, [UInt8]) -> Void) async throws -> Int32 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            queue.async {
                guard let dev = self.socket else {
                    cont.resume(throwing: NSError(domain: "ferry.darwin", code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "sandbox not booted"]))
                    return
                }
                dev.connect(toPort: darwinAgentPort) { r in
                    guard case .success(let conn) = r else {
                        cont.resume(throwing: NSError(domain: "ferry.darwin", code: 5,
                            userInfo: [NSLocalizedDescriptionKey: "agent connect: \(r)"]))
                        return
                    }
                    let fd = conn.fileDescriptor
                    var line = (try? JSONEncoder().encode(req)) ?? Data()
                    line.append(0x0A)
                    _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                    // Read frames on a background thread so the VM queue is not
                    // blocked; resume the continuation once the exit frame lands.
                    Thread {
                        var parser = DarwinFrameParser()
                        var status: Int32 = -1
                        var buf = [UInt8](repeating: 0, count: 64 * 1024)
                        loop: while true {
                            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                            if n <= 0 { break }
                            let frames = (try? parser.feed(Array(buf[0 ..< n]))) ?? []
                            for f in frames {
                                switch f.kind {
                                case .stdout, .stderr, .error:
                                    onOutput(f.kind, f.payload)
                                case .exit:
                                    status = DarwinFrameParser.exitStatus(f.payload)
                                    break loop
                                }
                            }
                        }
                        withExtendedLifetime(conn) {}
                        self.queue.async { cont.resume(returning: status) }
                    }.start()
                }
            }
        }
    }

    /// The vsock port the interactive agent (ferry-macagent-i) listens on, once
    /// ferry-cri has uploaded and launched it into the guest.
    static let interactiveAgentPort: UInt32 = 7001

    /// Upload the interactive agent binary and launch it in the guest (vsock 7001),
    /// so `kubectl exec -i/-it` has a stdin/PTY endpoint. No change to the golden
    /// image -- the baked agent (7000) does the upload and launch. Idempotent-ish:
    /// re-launching is harmless (bind fails, the first one keeps serving).
    func installInteractiveAgent(_ binary: Data) async throws {
        let b64 = "/private/var/ferry/ferry-macagent-i.b64"
        let bin = "/private/var/ferry/ferry-macagent-i"
        try await uploadBase64(binary, toGuestPath: b64)
        let log = "/private/var/ferry/ferry-macagent-i.log"
        // Background JUST the agent (with its own fds redirected) -- not a
        // `pgrep || agent &` subshell, which would inherit and hold this exec's
        // output pipes open and hang StartContainer.
        let script = "base64 -D < \"$0\" > \"$1\" && chmod +x \"$1\" && rm -f \"$0\"; "
            + "if ! pgrep -f \"$1\" >/dev/null 2>&1; then \"$1\" > \"$2\" 2>&1 < /dev/null & fi; "
            + "sleep 0.5; cat \"$2\" 2>/dev/null"
        let (_, out, err) = try await exec(DarwinRunRequest(argv: ["/bin/sh", "-c", script, b64, bin, log]))
        let msg = ((String(data: out, encoding: .utf8) ?? "") + (String(data: err, encoding: .utf8) ?? ""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !msg.isEmpty, !msg.contains("listening") {   // report only a launch problem
            FileHandle.standardError.write("darwin \(id): interactive agent: \(msg)\n".data(using: .utf8)!)
        }
    }

    /// Upload the DNS forwarder and run it in the guest (127.0.0.1:53), told the
    /// cluster DNS upstream and search domains. The caller then points the pod's
    /// resolver at it. As with the interactive agent, no golden change.
    func installDNSForwarder(_ binary: Data, upstream: String, searches: [String]) async throws {
        let b64 = "/private/var/ferry/ferry-macdns.b64"
        let bin = "/private/var/ferry/ferry-macdns"
        try await uploadBase64(binary, toGuestPath: b64)
        let args = ([upstream] + searches).map { "'\($0)'" }.joined(separator: " ")
        // if/then so only the forwarder (fds redirected) is backgrounded -- not a
        // `pgrep || … &` subshell, which would hold this exec's pipes open.
        let log = "/private/var/ferry/ferry-macdns.log"
        let script = "base64 -D < \"$0\" > \"$1\" && chmod +x \"$1\" && rm -f \"$0\"; "
            + "if ! pgrep -f \"$1\" >/dev/null 2>&1; then \"$1\" \(args) > \"$2\" 2>&1 < /dev/null & fi; "
            + "sleep 0.5"
        _ = try await exec(DarwinRunRequest(argv: ["/bin/sh", "-c", script, b64, bin, log]))
    }

    /// An open interactive session: write stdin/resize frames to the guest, read
    /// output through the `onOutput` given to `interactive`, await the exit code.
    final class Interactive: @unchecked Sendable {
        fileprivate let fd: Int32
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        fileprivate var code: Int32 = 0
        fileprivate var finished = false
        init(fd: Int32) { self.fd = fd }

        func writeStdin(_ data: [UInt8]) { frame(0, data) }
        func closeStdin() { frame(0, []) }
        func resize(cols: UInt16, rows: UInt16) {
            frame(4, [UInt8(cols >> 8), UInt8(cols & 0xff), UInt8(rows >> 8), UInt8(rows & 0xff)])
        }
        func wait() async -> Int32 {
            await withCheckedContinuation { (c: CheckedContinuation<Int32, Never>) in
                DispatchQueue.global().async { self.done.wait(); c.resume(returning: self.code) }
            }
        }
        fileprivate func finish(_ code: Int32) {
            lock.lock(); if !finished { finished = true; self.code = code; done.signal() }; lock.unlock()
        }
        private func frame(_ type: UInt8, _ payload: [UInt8]) {
            var f = [type]
            withUnsafeBytes(of: UInt32(payload.count).bigEndian) { f.append(contentsOf: $0) }
            f.append(contentsOf: payload)
            lock.lock(); defer { lock.unlock() }
            var off = 0
            while off < f.count { let w = f[off...].withUnsafeBytes { write(fd, $0.baseAddress, f.count - off) }; if w <= 0 { return }; off += w }
        }
    }

    private struct InteractiveRequest: Encodable {
        var argv: [String]; var env: [String: String]?; var chroot: String?; var tty: Bool
    }

    /// Open an interactive exec against the interactive agent (vsock 7001): send
    /// the request, stream the process's output to `onOutput`, and return a
    /// session to drive stdin/resize and await exit.
    func interactive(argv: [String], env: [String: String]?, chroot: String?, tty: Bool,
                     onOutput: @escaping @Sendable (DarwinFrameKind, [UInt8]) -> Void) async throws -> Interactive {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Interactive, Error>) in
            queue.async {
                guard let dev = self.socket else {
                    cont.resume(throwing: NSError(domain: "ferry.darwin", code: 6,
                        userInfo: [NSLocalizedDescriptionKey: "sandbox not booted"])); return
                }
                dev.connect(toPort: Self.interactiveAgentPort) { r in
                    guard case .success(let conn) = r else {
                        cont.resume(throwing: NSError(domain: "ferry.darwin", code: 7,
                            userInfo: [NSLocalizedDescriptionKey: "interactive agent connect: \(r)"])); return
                    }
                    let fd = conn.fileDescriptor
                    var line = (try? JSONEncoder().encode(InteractiveRequest(argv: argv, env: env, chroot: chroot, tty: tty))) ?? Data()
                    line.append(0x0A)
                    _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                    let session = Interactive(fd: fd)
                    Thread {
                        var parser = DarwinFrameParser()
                        var buf = [UInt8](repeating: 0, count: 64 * 1024)
                        var status: Int32 = 0
                        loop: while true {
                            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                            if n <= 0 { break }
                            for f in (try? parser.feed(Array(buf[0 ..< n]))) ?? [] {
                                switch f.kind {
                                case .stdout, .stderr, .error: onOutput(f.kind, f.payload)
                                case .exit: status = DarwinFrameParser.exitStatus(f.payload); break loop
                                }
                            }
                        }
                        withExtendedLifetime(conn) {}
                        session.finish(status)
                    }.start()
                    self.queue.async { cont.resume(returning: session) }
                }
            }
        }
    }

    /// A thread-safe byte accumulator for collecting a command's output; the run
    /// reader thread appends to it, the awaiting caller reads it once run returns.
    private final class Accum: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: [UInt8] = []
        func append(_ b: [UInt8]) { lock.lock(); bytes.append(contentsOf: b); lock.unlock() }
        var data: Data { lock.lock(); defer { lock.unlock() }; return Data(bytes) }
    }

    /// Run a command and collect its whole stdout/stderr and exit status -- for
    /// assembling the container root, moving files in, and exec probes, where the
    /// output is wanted in one piece rather than streamed.
    func exec(_ req: DarwinRunRequest) async throws -> (exit: Int32, stdout: Data, stderr: Data) {
        let out = Accum(), err = Accum()
        let code = try await run(req) { kind, payload in
            switch kind {
            case .stdout: out.append(payload)
            case .stderr, .error: err.append(payload)
            case .exit: break
            }
        }
        return (code, out.data, err.data)
    }

    /// Move `data` into the guest as base64 text at `path`, appended in chunks --
    /// the agent runs argv only and reads no stdin, so bytes travel this way (the
    /// same channel `ferry image build`'s COPY uses). The caller decodes it in
    /// the guest (`base64 -D < path | tar ...`). Chunks are plain base64 text, so
    /// there is no 4-byte-alignment constraint: the file is decoded whole.
    func uploadBase64(_ data: Data, toGuestPath path: String, chunkSize: Int = 128 * 1024) async throws {
        let b64 = data.base64EncodedString()
        let (c0, _, e0) = try await exec(DarwinRunRequest(
            argv: ["/bin/sh", "-c", "mkdir -p \"$(dirname \"$0\")\"; : > \"$0\"", path]))
        guard c0 == 0 else {
            throw NSError(domain: "ferry.darwin", code: 10,
                userInfo: [NSLocalizedDescriptionKey: "preparing \(path): \(String(data: e0, encoding: .utf8) ?? "")"])
        }
        var i = b64.startIndex
        while i < b64.endIndex {
            let j = b64.index(i, offsetBy: chunkSize, limitedBy: b64.endIndex) ?? b64.endIndex
            let piece = String(b64[i ..< j])
            let (c, _, e) = try await exec(DarwinRunRequest(
                argv: ["/bin/sh", "-c", "printf %s \"$1\" >> \"$0\"", path, piece]))
            guard c == 0 else {
                throw NSError(domain: "ferry.darwin", code: 11,
                    userInfo: [NSLocalizedDescriptionKey: "uploading to \(path): \(String(data: e, encoding: .utf8) ?? "")"])
            }
            i = j
        }
    }

    /// Ask the guest to halt, force it after a grace period, then delete the
    /// clone. Safe to call more than once.
    func shutdown() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                guard let machine = self.vm, let dev = self.socket, !self.stopped else {
                    self.cleanup(); cont.resume(); return
                }
                self.delegate?.onStop = {
                    self.queue.async { self.cleanup(); cont.resume() }
                }
                if let line = try? JSONEncoder().encode(DarwinRunRequest(argv: ["/sbin/shutdown", "-h", "now"])) {
                    dev.connect(toPort: darwinAgentPort) { r in
                        guard case .success(let conn) = r else { return }
                        var l = line; l.append(0x0A)
                        _ = l.withUnsafeBytes { write(conn.fileDescriptor, $0.baseAddress, $0.count) }
                        self.queue.async { self.connections.append(conn) }
                    }
                }
                self.queue.asyncAfter(deadline: .now() + 30) {
                    if machine.state != .stopped {
                        machine.stop { _ in self.queue.async { self.cleanup(); cont.resume() } }
                    }
                }
            }
        }
    }

    /// Runs on `queue`. Drops the VM and removes the clone's disk.
    private func cleanup() {
        connections = []
        vm = nil
        socket = nil
        try? FileManager.default.removeItem(at: workDir)
    }
}
