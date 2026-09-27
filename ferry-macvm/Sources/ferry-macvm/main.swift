// ferry-macvm boots a throwaway macOS VM and runs RUN's build steps in it,
// for `ferry image build --os darwin`. It is the other half of what makes
// RUN possible there: a darwin image is FROM scratch plus COPY -- no base to
// run and no Linux worker that could run Darwin binaries -- so build steps
// that need one run here instead, on a Mac, in a VM cloned from the same
// golden macOS bundle FERRY_MAC_IMAGE already points at for machines.
//
//   ferry-macvm build <golden-bundle>
//
// Clones golden (an APFS clonefile, instant and copy-on-write), boots the
// clone, and then, once ferry-macagent answers, reads one exec request per
// line of stdin -- {"argv":[...],"env":{...},"cwd":"..."} -- relaying the
// agent's own response frames (type 1 stdout, 2 stderr, 3 exit, 4 error; see
// experiments/39-macos-pods/agent.swift) back out on fd 3, verbatim, in
// order. ferry-mkimage is the process on the other end of both: it drives
// this as a coprocess, one request per COPY or RUN instruction, and asks for
// nothing else. On stdin EOF, the guest is shut down and its clone deleted.
//
// There is deliberately no shared directory between host and guest. An
// earlier design gave the guest a writable virtiofs share and had COPY/RUN
// use it directly; on the host this was built and tested on, that share
// denied the guest read access ("Operation not permitted") to anything
// tagged com.apple.provenance, which turned out to be everything -- see
// experiments/40-mac-build-run/FINDINGS.md. Files move as bytes through this
// same exec channel instead (a tar piped through argv, base64-encoded, for
// now -- see FINDINGS.md's "what would have to change" for why that is a
// stopgap and not the shape this should keep).
import Foundation
import Virtualization

setvbuf(stdout, nil, _IONBF, 0)

let agentPort: UInt32 = 7000
let t0 = Date()
func stamp() -> String { String(format: "%7.2fs", Date().timeIntervalSince(t0)) }
// stderr, not stdout: fd 1 is reserved for the relayed frames on fd 3.
func log(_ s: String) { FileHandle.standardError.write("\(stamp())  \(s)\n".data(using: .utf8)!) }
func die(_ s: String) -> Never { FileHandle.standardError.write("ferry-macvm: \(s)\n".data(using: .utf8)!); exit(1) }

struct Bundle {
    let dir: URL
    var hardwareModel: URL { dir.appendingPathComponent("HardwareModel.bin") }
    var machineIdentifier: URL { dir.appendingPathComponent("MachineIdentifier.bin") }
    var auxiliary: URL { dir.appendingPathComponent("AuxiliaryStorage") }
    var disk: URL { dir.appendingPathComponent("Disk.img") }
}

func configuration(_ b: Bundle, cpus: Int, memory: UInt64) throws -> VZVirtualMachineConfiguration {
    let platform = VZMacPlatformConfiguration()
    guard let hw = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: b.hardwareModel)),
          let mid = VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: b.machineIdentifier))
    else { die("unreadable bundle \(b.dir.path)") }
    platform.hardwareModel = hw
    platform.machineIdentifier = mid
    platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: b.auxiliary)

    let c = VZVirtualMachineConfiguration()
    c.platform = platform
    c.bootLoader = VZMacOSBootLoader()
    c.cpuCount = cpus
    c.memorySize = memory
    let disk = try VZDiskImageStorageDeviceAttachment(url: b.disk, readOnly: false,
                                                      cachingMode: .automatic, synchronizationMode: .full)
    c.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]
    let nic = VZVirtioNetworkDeviceConfiguration()
    nic.attachment = VZNATNetworkDeviceAttachment()
    c.networkDevices = [nic]
    let gfx = VZMacGraphicsDeviceConfiguration()
    gfx.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1440, heightInPixels: 900, pixelsPerInch: 80)]
    c.graphicsDevices = [gfx]
    c.keyboards = [VZUSBKeyboardConfiguration()]
    c.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    c.socketDevices = [VZVirtioSocketDeviceConfiguration()]
    c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    try c.validate()
    return c
}

// One serial queue for the whole VM's lifetime, in the shape
// experiments/18-node-image/Sources/ferry-node/MacMachine.swift uses: giving
// VZVirtualMachine its own queue instead of the implicit main-queue init
// keeps every callback's isolation tied to *this* queue, not the main actor,
// which is what lets connect/start/stop completion handlers below capture
// Virtualization's own (non-Sendable) types without Swift's strict
// concurrency checker rejecting the build.
let vmQueue = DispatchQueue(label: "ferry.macvm.build")

// Deliberately global, mutable, and touched from more than one queue: this
// only ever appends (nothing here removes from it before the process exits),
// so there is nothing for isolation to protect against. The same pattern
// ferry-gpud/Sources/ferry-gpud/Service.swift uses for its own unsafe var.
nonisolated(unsafe) var keep: [AnyObject] = []

final class Delegate: NSObject, VZVirtualMachineDelegate {
    let name: String
    var onStop: () -> Void = {}
    init(name: String) { self.name = name }
    func guestDidStop(_ vm: VZVirtualMachine) { log("\(name): guest stopped"); onStop() }
    func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) { log("\(name): stopped with error \(error)"); onStop() }
}

/// Retries the agent's port until it answers: that moment is when the VM
/// could first run a build step, which is the number that matters, not VM
/// start.
func waitForAgent(_ vm: VZVirtualMachine, name: String, then: @escaping (VZVirtioSocketDevice) -> Void) {
    guard let dev = vm.socketDevices.first as? VZVirtioSocketDevice else { die("no vsock device") }
    func attempt() {
        dev.connect(toPort: agentPort) { r in
            switch r {
            case .success(let conn):
                // Held rather than closed: closing it and opening the next one
                // from inside this callback crashed the framework (objc_release
                // in SocketDeviceMessenger::did_open_guest_virtio_socket).
                keep.append(conn)
                log("\(name): agent answering")
                vmQueue.async { then(dev) }
            case .failure:
                vmQueue.asyncAfter(deadline: .now() + 0.1, execute: attempt)
            }
        }
    }
    attempt()
}

func boot(_ b: Bundle, name: String, cpus: Int = 4, memory: UInt64 = 8 << 30,
          ready: @escaping (VZVirtualMachine, VZVirtioSocketDevice) -> Void,
          failed: @escaping (Error) -> Void) {
    let c: VZVirtualMachineConfiguration
    do { c = try configuration(b, cpus: cpus, memory: memory) } catch { return failed(error) }
    let vm = VZVirtualMachine(configuration: c, queue: vmQueue)
    let d = Delegate(name: name)
    keep.append(vm); keep.append(d)
    let started = Date()
    // Virtualization.framework asserts (dispatch_assert_queue) that every
    // operation on a VM created with an explicit queue is actually performed
    // from that queue -- constructing it with one is not enough on its own.
    vmQueue.async {
        vm.delegate = d
        vm.start(options: VZMacOSVirtualMachineStartOptions()) { error in
            if let error { return failed(error) }
            log(String(format: "%@: VM started in %.2fs", name, Date().timeIntervalSince(started)))
            waitForAgent(vm, name: name) { dev in ready(vm, dev) }
        }
    }
}

/// Stops the guest the way a build should end: ask it to shut down, and only
/// pull the plug if it does not.
func stop(_ vm: VZVirtualMachine, _ dev: VZVirtioSocketDevice, name: String, then: @escaping () -> Void) {
    (vm.delegate as? Delegate)?.onStop = then
    let req = try! JSONEncoder().encode(RunRequest(argv: ["/sbin/shutdown", "-h", "now"]))
    dev.connect(toPort: agentPort) { r in
        guard case .success(let conn) = r else { return }
        var line = req; line.append(0x0A)
        _ = line.withUnsafeBytes { write(conn.fileDescriptor, $0.baseAddress, $0.count) }
        keep.append(conn)
    }
    vmQueue.asyncAfter(deadline: .now() + 60) {
        if vm.state != .stopped { log("\(name): forcing stop"); vm.stop { _ in then() } }
    }
}

/// A build VM's disk: a copy-on-write clone of the golden image, so it costs
/// microseconds and nothing is shared with -- or can leak back into -- the
/// golden bundle itself.
func clone(_ golden: Bundle, to dir: URL) throws -> Bundle {
    try? FileManager.default.removeItem(at: dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let p = Bundle(dir: dir)
    let start = Date()
    for (s, d) in [(golden.disk, p.disk), (golden.auxiliary, p.auxiliary), (golden.hardwareModel, p.hardwareModel)] {
        guard clonefile(s.path, d.path, 0) == 0 else { throw NSError(domain: "clonefile", code: Int(errno)) }
    }
    try VZMacMachineIdentifier().dataRepresentation.write(to: p.machineIdentifier)
    log(String(format: "cloned golden bundle in %.1f ms", Date().timeIntervalSince(start) * 1000))
    return p
}

// MARK: the exec protocol -- agent.swift's request shape and frame format

struct RunRequest: Codable { var argv: [String]; var env: [String: String]? = nil; var cwd: String? = nil }

/// relayFrame writes agent.swift's own [type u8][length u32 BE][payload]
/// frame to fd 3, unchanged -- so the driver on the other end decodes the
/// exact protocol the guest speaks, with no re-encoding and no second,
/// racing channel for the exit status.
let ctrlFD: Int32 = 3
func relayFrame(_ type: UInt8, _ payload: [UInt8]) {
    var frame: [UInt8] = [type]
    let n = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: n) { frame.append(contentsOf: $0) }
    frame.append(contentsOf: payload)
    var off = 0
    while off < frame.count {
        let w = frame[off...].withUnsafeBytes { write(ctrlFD, $0.baseAddress, $0.count) }
        if w <= 0 { return }
        off += w
    }
}

func runRelay(_ dev: VZVirtioSocketDevice, _ req: RunRequest, done: @escaping (Int32) -> Void) {
    dev.connect(toPort: agentPort) { r in
        guard case .success(let conn) = r else {
            relayFrame(4, Array("connect: \(r)".utf8)); done(-1); return
        }
        let fd = conn.fileDescriptor
        var line = try! JSONEncoder().encode(req)
        line.append(0x0A)
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        Thread {
            func readExact(_ n: Int) -> [UInt8]? {
                var buf = [UInt8](repeating: 0, count: n), off = 0
                while off < n {
                    let got = buf[off...].withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                    if got <= 0 { return nil }
                    off += got
                }
                return buf
            }
            var status: Int32 = -1
            while let h = readExact(5) {
                let len = Int(UInt32(h[1]) << 24 | UInt32(h[2]) << 16 | UInt32(h[3]) << 8 | UInt32(h[4]))
                guard let payload = readExact(len) else { break }
                relayFrame(h[0], payload)
                if h[0] == 3 {
                    status = Int32(bitPattern: UInt32(payload[0]) << 24 | UInt32(payload[1]) << 16
                                   | UInt32(payload[2]) << 8 | UInt32(payload[3]))
                }
            }
            withExtendedLifetime(conn) {}
            vmQueue.async { done(status) }
        }.start()
    }
}

func readStdinLine() -> [UInt8]? {
    var line: [UInt8] = []
    var byte: UInt8 = 0
    while read(0, &byte, 1) == 1 {
        if byte == 0x0A { return line }
        line.append(byte)
    }
    return line.isEmpty ? nil : line
}

// MARK: main

let args = Array(CommandLine.arguments.dropFirst())
guard args.first == "build", args.count == 2 else {
    die("usage: ferry-macvm build <golden-bundle>")
}
let golden = Bundle(dir: URL(fileURLWithPath: args[1]))
let workDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("ferry-macvm-build-\(ProcessInfo.processInfo.globallyUniqueString)")
let clonedBundle = try! clone(golden, to: workDir)

boot(clonedBundle, name: "build", ready: { vm, dev in
    func loop() {
        DispatchQueue.global().async {
            guard let line = readStdinLine() else {
                vmQueue.async {
                    stop(vm, dev, name: "build") { try? FileManager.default.removeItem(at: workDir); exit(0) }
                }
                return
            }
            guard let req = try? JSONDecoder().decode(RunRequest.self, from: Data(line)) else {
                relayFrame(4, Array("malformed request".utf8))
                loop()
                return
            }
            vmQueue.async { runRelay(dev, req) { _ in loop() } }
        }
    }
    loop()
}, failed: { error in
    try? FileManager.default.removeItem(at: workDir)
    die("start: \(error)")
})

RunLoop.main.run()
