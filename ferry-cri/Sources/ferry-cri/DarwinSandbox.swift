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

    init(id: String, golden: URL, workDir: URL, cpus: Int, memoryBytes: UInt64) {
        self.id = id
        self.golden = DarwinBundle(dir: golden)
        self.workDir = workDir
        self.cpus = max(1, cpus)
        self.memoryBytes = memoryBytes
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
        // NAT for now: outbound works, which is enough to prove the sandbox and
        // to pull nothing (the image is already on the guest's disk). Cluster
        // networking -- the pod switch, an address on ferry's machine network --
        // is the follow-up in the design doc.
        let nic = VZVirtioNetworkDeviceConfiguration()
        nic.attachment = VZNATNetworkDeviceAttachment()
        c.networkDevices = [nic]
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
