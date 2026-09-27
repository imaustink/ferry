// macvm: what a macOS pod would cost ferry-cri, measured with
// Virtualization.framework alone.
//
//   macvm install <ipsw> <golden>              restore macOS into a new bundle
//   macvm boot <bundle> [--gui] [-- cmd...]     boot a bundle in place, wait for the
//                                              agent, optionally run a command
//   macvm pod <golden> <pod> [-- cmd...]        clone the golden bundle (APFS clonefile),
//                                              boot the clone, run a command, stop, delete
//   macvm ceiling <golden> <n>                 boot n clones at once, report where it stops
//
// A bundle is the directory Apple's sample code uses: HardwareModel.bin,
// MachineIdentifier.bin, AuxiliaryStorage and Disk.img.

import AppKit
import Foundation
import Virtualization

setvbuf(stdout, nil, _IONBF, 0)

let agentPort: UInt32 = 7000
let t0 = Date()
func stamp() -> String { String(format: "%7.2fs", Date().timeIntervalSince(t0)) }
func log(_ s: String) { print("\(stamp())  \(s)") }
func die(_ s: String) -> Never { FileHandle.standardError.write("macvm: \(s)\n".data(using: .utf8)!); exit(1) }

struct Bundle {
    let dir: URL
    var hardwareModel: URL { dir.appendingPathComponent("HardwareModel.bin") }
    var machineIdentifier: URL { dir.appendingPathComponent("MachineIdentifier.bin") }
    var auxiliary: URL { dir.appendingPathComponent("AuxiliaryStorage") }
    var disk: URL { dir.appendingPathComponent("Disk.img") }
}

func configuration(_ b: Bundle, cpus: Int, memory: UInt64, gui: Bool) throws -> VZVirtualMachineConfiguration {
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
    // --share DIR: a read-only virtiofs share tagged "ferry", which the guest
    // mounts itself (mount_virtiofs ferry <dir>) -- the automount tag only
    // mounts once a user logs in, and nobody does.
    if let dir = shareDir {
        let fs = VZVirtioFileSystemDeviceConfiguration(tag: "ferry")
        fs.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: dir, readOnly: true))
        c.directorySharingDevices = [fs]
    }
    _ = gui
    try c.validate()
    return c
}

// MARK: install

func install(ipsw: URL, golden: URL) {
    VZMacOSRestoreImage.load(from: ipsw) { result in
        DispatchQueue.main.async {
            guard case .success(let image) = result else { die("load restore image: \(result)") }
            guard let req = image.mostFeaturefulSupportedConfiguration, req.hardwareModel.isSupported else {
                die("this host cannot run \(image.buildVersion)")
            }
            log("restore image \(image.buildVersion); needs \(req.minimumSupportedCPUCount) cpus, \(req.minimumSupportedMemorySize >> 30) GiB")
            let b = Bundle(dir: golden)
            do {
                try FileManager.default.createDirectory(at: golden, withIntermediateDirectories: true)
                try req.hardwareModel.dataRepresentation.write(to: b.hardwareModel)
                try VZMacMachineIdentifier().dataRepresentation.write(to: b.machineIdentifier)
                _ = try VZMacAuxiliaryStorage(creatingStorageAt: b.auxiliary, hardwareModel: req.hardwareModel, options: [])
                FileManager.default.createFile(atPath: b.disk.path, contents: nil)
                let h = try FileHandle(forWritingTo: b.disk)
                try h.truncate(atOffset: 64 << 30)  // sparse; APFS only spends what is written
                try h.close()
                let c = try configuration(b, cpus: max(4, req.minimumSupportedCPUCount),
                                          memory: max(8 << 30, req.minimumSupportedMemorySize), gui: false)
                let vm = VZVirtualMachine(configuration: c)
                let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw)
                var last = -1
                let obs = installer.progress.observe(\.fractionCompleted) { p, _ in
                    let pct = Int(p.fractionCompleted * 100)
                    if pct != last { last = pct; log("install \(pct)%") }
                }
                installer.install { r in
                    _ = obs
                    switch r {
                    case .success: log("installed into \(golden.path)"); exit(0)
                    case .failure(let e): die("install: \(e)")
                    }
                }
                keep.append(installer)
            } catch { die("\(error)") }
        }
    }
}

// MARK: boot, agent, run

var keep: [AnyObject] = []
var shareDir: URL? = {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: "--share"), i + 1 < a.count,
          i < (a.firstIndex(of: "--") ?? a.count) else { return nil }
    return URL(fileURLWithPath: a[i + 1])
}()

final class Delegate: NSObject, VZVirtualMachineDelegate {
    let name: String
    var onStop: () -> Void = {}
    init(name: String) { self.name = name }
    func guestDidStop(_ vm: VZVirtualMachine) { log("\(name): guest stopped"); onStop() }
    func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) { log("\(name): stopped with error \(error)"); onStop() }
}

/// Retries the agent's port until it answers: that moment is when the pod could
/// first run a container, which is the number that matters, not VM start.
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
                DispatchQueue.main.async { then(dev) }
            case .failure:
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: attempt)
            }
        }
    }
    attempt()
}

struct RunRequest: Encodable { var argv: [String]; var chroot: String? }

/// Sends one request to the agent and relays its frames; calls back with the exit status.
func run(_ dev: VZVirtioSocketDevice, _ req: RunRequest, quiet: Bool = false, done: @escaping (Int32) -> Void) {
    dev.connect(toPort: agentPort) { r in
        guard case .success(let conn) = r else { die("connect: \(r)") }
        let fd = conn.fileDescriptor
        var line = try! JSONEncoder().encode(req)
        line.append(0x0A)
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        Thread {
            func readExact(_ n: Int) -> [UInt8]? {
                var buf = [UInt8](repeating: 0, count: n), off = 0
                while off < n {
                    let r = buf[off...].withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                    if r <= 0 { return nil }
                    off += r
                }
                return buf
            }
            var status: Int32 = -1
            while let h = readExact(5) {
                let len = Int(UInt32(h[1]) << 24 | UInt32(h[2]) << 16 | UInt32(h[3]) << 8 | UInt32(h[4]))
                guard let p = readExact(len) else { break }
                switch h[0] {
                case 1: if !quiet { FileHandle.standardOutput.write(Data(p)) }
                case 2: if !quiet { FileHandle.standardError.write(Data(p)) }
                case 3: status = Int32(bitPattern: UInt32(p[0]) << 24 | UInt32(p[1]) << 16 | UInt32(p[2]) << 8 | UInt32(p[3]))
                default: FileHandle.standardError.write("agent: \(String(decoding: p, as: UTF8.self))\n".data(using: .utf8)!)
                }
            }
            withExtendedLifetime(conn) {}
            DispatchQueue.main.async { done(status) }
        }.start()
    }
}

func boot(_ b: Bundle, name: String, gui: Bool, recovery: Bool = false, cpus: Int = 4, memory: UInt64 = 4 << 30,
          ready: @escaping (VZVirtualMachine, VZVirtioSocketDevice) -> Void,
          failed: @escaping (Error) -> Void = { die("start: \($0)") }) {
    let c: VZVirtualMachineConfiguration
    do { c = try configuration(b, cpus: cpus, memory: memory, gui: gui) } catch { return failed(error) }
    let vm = VZVirtualMachine(configuration: c)
    let d = Delegate(name: name)
    vm.delegate = d
    keep.append(vm); keep.append(d)
    if gui { showWindow(vm, title: name) }
    let started = Date()
    let options = VZMacOSVirtualMachineStartOptions()
    options.startUpFromMacOSRecovery = recovery
    vm.start(options: options) { error in
        if let error { return failed(error) }
        log(String(format: "%@: VM started in %.2fs%@", name, Date().timeIntervalSince(started),
                   recovery ? ", into recoveryOS" : ""))
        // recoveryOS is its own system on its own volume: the agent is not there.
        if recovery { d.onStop = { exit(0) }; return }
        waitForAgent(vm, name: name) { dev in ready(vm, dev) }
    }
}

func showWindow(_ vm: VZVirtualMachine, title: String) {
    NSApplication.shared.setActivationPolicy(.regular)
    let view = VZVirtualMachineView()
    view.virtualMachine = vm
    view.capturesSystemKeys = true
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                     styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    w.title = title
    w.contentView = view
    w.center()
    w.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
    keep.append(w)
}

/// Stops the guest the way a pod stop should: ask it to shut down, and only
/// pull the plug if it does not.
func stop(_ vm: VZVirtualMachine, _ dev: VZVirtioSocketDevice, name: String, then: @escaping () -> Void) {
    (vm.delegate as? Delegate)?.onStop = then
    run(dev, RunRequest(argv: ["/sbin/shutdown", "-h", "now"]), quiet: true) { _ in }
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
        if vm.state != .stopped { log("\(name): forcing stop"); vm.stop { _ in then() } }
    }
}

/// A pod's disk: a copy-on-write clone of the golden image, so it costs nothing
/// until the guest writes. Each clone gets a fresh machine identifier unless
/// `sameID` -- which matters once the golden image's security policy has been
/// changed, because that policy is personalised to the identifier it was made on.
func clone(_ golden: Bundle, to dir: URL, sameID: Bool = false) throws -> Bundle {
    try? FileManager.default.removeItem(at: dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let p = Bundle(dir: dir)
    let start = Date()
    for (s, d) in [(golden.disk, p.disk), (golden.auxiliary, p.auxiliary), (golden.hardwareModel, p.hardwareModel)] {
        guard clonefile(s.path, d.path, 0) == 0 else { throw NSError(domain: "clonefile", code: Int(errno)) }
    }
    if sameID {
        guard clonefile(golden.machineIdentifier.path, p.machineIdentifier.path, 0) == 0 else {
            throw NSError(domain: "clonefile", code: Int(errno))
        }
    } else {
        try VZMacMachineIdentifier().dataRepresentation.write(to: p.machineIdentifier)
    }
    log(String(format: "cloned golden bundle in %.1f ms%@", Date().timeIntervalSince(start) * 1000,
               sameID ? ", keeping its machine identifier" : ""))
    return p
}

// MARK: main

var args = Array(CommandLine.arguments.dropFirst())
func take() -> String { guard !args.isEmpty else { die("missing argument") }; return args.removeFirst() }
func command() -> [String] {
    guard let i = args.firstIndex(of: "--") else { return [] }
    defer { args.removeSubrange(i...) }
    return Array(args[(i + 1)...])
}

switch args.first {
case "install":
    args.removeFirst()
    install(ipsw: URL(fileURLWithPath: take()), golden: URL(fileURLWithPath: take()))

case "boot":
    args.removeFirst()
    let cmd = command()
    let b = Bundle(dir: URL(fileURLWithPath: take()))
    let recovery = args.contains("--recovery")
    let gui = args.contains("--gui") || recovery
    boot(b, name: b.dir.lastPathComponent, gui: gui, recovery: recovery, ready: { vm, dev in
        guard !cmd.isEmpty else {
            if gui { log("agent up; close the window or ^C to stop") } else { stop(vm, dev, name: "boot") { exit(0) } }
            return
        }
        run(dev, RunRequest(argv: cmd)) { status in
            log("exit \(status)")
            if !gui { stop(vm, dev, name: "boot") { exit(status) } }
        }
    }, failed: { die("start: \($0)") })

case "pod":
    args.removeFirst()
    let cmd = command()
    let golden = Bundle(dir: URL(fileURLWithPath: take()))
    let podDir = URL(fileURLWithPath: take())
    let root = args.firstIndex(of: "--chroot").map { args[$0 + 1] }
    let p = try! clone(golden, to: podDir, sameID: args.contains("--same-id"))
    let asked = Date()
    boot(p, name: podDir.lastPathComponent, gui: false, ready: { vm, dev in
        log(String(format: "pod ready %.2fs after clone", Date().timeIntervalSince(asked)))
        let argv = cmd.isEmpty ? ["/usr/bin/sw_vers"] : cmd
        let runStart = Date()
        run(dev, RunRequest(argv: argv, chroot: root)) { status in
            log(String(format: "exit %d in %.0f ms", status, Date().timeIntervalSince(runStart) * 1000))
            let stopStart = Date()
            stop(vm, dev, name: "pod") {
                log(String(format: "stopped in %.2fs", Date().timeIntervalSince(stopStart)))
                try? FileManager.default.removeItem(at: podDir)
                exit(status)
            }
        }
    })

case "ceiling":
    args.removeFirst()
    let golden = Bundle(dir: URL(fileURLWithPath: take()))
    let n = Int(take()) ?? 3
    let sameID = args.contains("--same-id")
    let base = golden.dir.deletingLastPathComponent().appendingPathComponent("ceiling")
    var up = 0, settled = 0
    func settle() {
        settled += 1
        if settled == n { log("\(up) of \(n) macOS guests running at once"); exit(0) }
    }
    for i in 0..<n {
        let p = try! clone(golden, to: base.appendingPathComponent("vm\(i)"), sameID: sameID)
        boot(p, name: "vm\(i)", gui: false, ready: { _, _ in up += 1; settle() },
             failed: { e in log("vm\(i): refused: \(e.localizedDescription)"); settle() })
    }

default:
    die("usage: macvm install|boot|pod|ceiling ...")
}

NSApplication.shared.run()
