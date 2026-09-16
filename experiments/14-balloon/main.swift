// Can a pod VM be resized while it is running?
//
// Ferry sizes a pod's VM when it boots and never revisits it, which makes the
// default a guess: too small and a pod that needs memory cannot have it, too
// large and the guest keeps whatever it touched forever. Virtualization.framework
// has a memory balloon -- a device that takes memory back from a running guest
// -- and Apple's own guest kernel configuration enables the driver, but nothing
// in the stack ferry builds on attaches one.
//
// This boots a VM with a balloon, has the guest dirty a large block and release
// it, then asks for the memory back and watches what the host actually gets.
// The guest reports its own MemTotal throughout, so a balloon that inflated can
// be told from a request that was ignored.
//
// Virtualization.framework alone: no Containerization, no ferry-cri.

import Foundation
import Virtualization

struct Options {
    var kernel = "../../kernel/vmlinux-arm64"
    var initrd = "build/initramfs.cpio"
    var memoryMiB: UInt64 = 4096
    var targetMiB: UInt64 = 512
    var touchMiB: UInt64 = 2048
    var cpuCount = 2
    var settle = 5.0
    var bootTimeout = 30.0
    var pressureMiB = 0
}

func parseOptions() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while let flag = args.first {
        args.removeFirst()
        func value() -> String {
            guard let v = args.first else {
                FileHandle.standardError.write("missing value for \(flag)\n".data(using: .utf8)!)
                exit(2)
            }
            args.removeFirst()
            return v
        }
        switch flag {
        case "--kernel":  o.kernel = value()
        case "--initrd":  o.initrd = value()
        case "--memory":  o.memoryMiB = UInt64(value()) ?? o.memoryMiB
        case "--target":  o.targetMiB = UInt64(value()) ?? o.targetMiB
        case "--touch":   o.touchMiB = UInt64(value()) ?? o.touchMiB
        case "--cpus":    o.cpuCount = Int(value()) ?? o.cpuCount
        case "--settle":  o.settle = Double(value()) ?? o.settle
        case "--pressure": o.pressureMiB = Int(value()) ?? o.pressureMiB
        case "--timeout": o.bootTimeout = Double(value()) ?? o.bootTimeout
        default:
            FileHandle.standardError.write("unknown flag \(flag)\n".data(using: .utf8)!)
            exit(2)
        }
    }
    return o
}

/// Collects the guest's console so the host can wait for a marker and, later,
/// read back the last thing the guest said about its own memory.
final class Console {
    private let pipe = Pipe()
    private let lock = NSLock()
    private var text = ""
    private var waiting: (marker: String, semaphore: DispatchSemaphore)?

    init() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            guard !chunk.isEmpty, let piece = String(data: chunk, encoding: .utf8) else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            self.text += piece
            if let waiting = self.waiting, self.text.contains(waiting.marker) {
                self.waiting = nil
                waiting.semaphore.signal()
            }
        }
    }

    var attachment: VZSerialPortAttachment {
        VZFileHandleSerialPortAttachment(
            fileHandleForReading: Pipe().fileHandleForReading,
            fileHandleForWriting: pipe.fileHandleForWriting)
    }

    func wait(for marker: String, timeout: TimeInterval) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        lock.lock()
        if text.contains(marker) {
            lock.unlock()
            return true
        }
        waiting = (marker, semaphore)
        lock.unlock()
        return semaphore.wait(timeout: .now() + timeout) == .success
    }

    /// Console lines matching a needle, for the parts of the guest's report
    /// that are read once rather than watched.
    func lines(containing needle: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return text.split(separator: "\n").map(String.init).filter { $0.contains(needle) }
    }

    /// The guest's latest view of its own memory, in MiB. Both numbers matter:
    /// inflating the balloon takes pages out of MemFree and out of MemTotal, so
    /// a guest that inflated but a host that kept the pages anyway is a
    /// different finding from a guest that never inflated at all.
    func guestMemory() -> (total: Int, free: Int) {
        lock.lock()
        defer { lock.unlock() }
        let lines = text.split(separator: "\n").filter { $0.contains("MemTotal=") }
        guard let last = lines.last else { return (-1, -1) }
        var total = -1, free = -1
        for raw in last.split(separator: " ") {
            // The console is a serial line: fields can carry a trailing CR,
            // which parses as nothing at all rather than as the number it is.
            let field = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if field.hasPrefix("MemTotal=") { total = Int(field.dropFirst(9)) ?? -1 }
            if field.hasPrefix("MemFree=") { free = Int(field.dropFirst(8)) ?? -1 }
        }
        return (total, free)
    }
}

// MARK: - Host accounting

/// Every Virtualization.framework VM process on the machine. They are children
/// of launchd, so the probe finds its own by diffing this set across the start.
func vmProcessIDs() -> Set<Int> {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-Ao", "pid=,comm="]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    var found = Set<Int>()
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        guard line.contains("Virtualization.VirtualMachine") else { continue }
        if let pid = Int(line.split(separator: " ").first ?? "") { found.insert(pid) }
    }
    return found
}

/// What macOS charges the VM process, in MiB. Physical footprint rather than
/// resident size: the framework maps a large amount of shared library text into
/// every VM process, and counting that would drown the signal.
func footprintMiB(_ pid: Int) -> Double? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/vmmap")
    process.arguments = ["--summary", "\(pid)"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n")
    where line.hasPrefix("Physical footprint:") {
        var value = line.dropFirst("Physical footprint:".count)
            .trimmingCharacters(in: .whitespaces)
        var scale = 1.0
        if value.hasSuffix("G") { scale = 1024; value.removeLast() }
        else if value.hasSuffix("M") { scale = 1; value.removeLast() }
        else if value.hasSuffix("K") { scale = 1.0 / 1024; value.removeLast() }
        if let n = Double(value) { return n * scale }
    }
    return nil
}

/// Resident size of the VM process, in MiB. Coarser than footprint — it counts
/// the shared framework text every VM maps — but it moves for reasons footprint
/// might not, and a reclaim that shows in neither did not happen.
func residentMiB(_ pid: Int) -> Double {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "rss=", "-p", "\(pid)"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return (Double(text) ?? 0) / 1024
}

/// Free memory for the whole machine, in MiB. The last word on whether pages
/// came back: it is the host's own accounting rather than any one process's.
func hostFreeMiB() -> Double {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/vm_stat")
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    var pages = 0.0
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        guard line.hasPrefix("Pages free:") || line.hasPrefix("Pages speculative:"),
              let value = line.split(separator: ":").last else { continue }
        pages += Double(value.trimmingCharacters(in: CharacterSet(charactersIn: " ."))) ?? 0
    }
    return pages * 16384 / 1024 / 1024
}

// MARK: - Probe

let options = parseOptions()
for path in [options.kernel, options.initrd] where !FileManager.default.fileExists(atPath: path) {
    FileHandle.standardError.write("missing \(path); run ./build.sh first\n".data(using: .utf8)!)
    exit(1)
}

print("""
==> balloon probe
    kernel   \(options.kernel)
    VM       \(options.cpuCount) cpu, \(options.memoryMiB) MiB configured
    guest    dirties \(options.touchMiB) MiB, then releases it
    request  shrink to \(options.targetMiB) MiB, then restore
""")

let console = Console()
let config = VZVirtualMachineConfiguration()
config.cpuCount = options.cpuCount
config.memorySize = options.memoryMiB * 1024 * 1024

let bootLoader = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: options.kernel))
bootLoader.initialRamdiskURL = URL(fileURLWithPath: options.initrd)
bootLoader.commandLine = "console=hvc0 panic=-1 ferry.touch=\(options.touchMiB)"
config.bootLoader = bootLoader

let port = VZVirtioConsoleDeviceSerialPortConfiguration()
port.attachment = console.attachment
config.serialPorts = [port]

// The device under test. Nothing else in ferry's stack asks for one.
config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

do {
    try config.validate()
} catch {
    FileHandle.standardError.write("configuration invalid: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}

let queue = DispatchQueue(label: "ferry.balloon")
let before = vmProcessIDs()
let vm = VZVirtualMachine(configuration: config, queue: queue)

let started = DispatchSemaphore(value: 0)
var startError: Error?
queue.async {
    vm.start { result in
        if case .failure(let error) = result { startError = error }
        started.signal()
    }
}
guard started.wait(timeout: .now() + 30) == .success, startError == nil else {
    FileHandle.standardError.write(
        "failed to start: \(startError?.localizedDescription ?? "timed out")\n".data(using: .utf8)!)
    exit(1)
}

guard console.wait(for: "guest userspace up", timeout: options.bootTimeout) else {
    FileHandle.standardError.write("guest never reached userspace\n".data(using: .utf8)!)
    exit(1)
}

// Identify this VM's process, so the footprint being reported is this VM's and
// not a pod belonging to a cluster running on the same Mac.
Thread.sleep(forTimeInterval: 1)
let mine = vmProcessIDs().subtracting(before)
guard mine.count == 1, let pid = mine.first else {
    FileHandle.standardError.write(
        "expected exactly one new VM process, found \(mine.count)\n".data(using: .utf8)!)
    exit(1)
}

var rows: [(String, Double, Int)] = []
func record(_ stage: String) {
    let footprint = footprintMiB(pid) ?? -1
    let guest = console.guestMemory()
    rows.append((stage, footprint, guest.total))
    print(String(format: "    %-22s footprint %6.0f  rss %6.0f  free %6.0f   guest total %5d  free %5d",
                 (stage as NSString).utf8String!, footprint, residentMiB(pid), hostFreeMiB(),
                 guest.total, guest.free))
}

print("\n==> what the guest found")
for line in console.lines(containing: "virtio") {
    print("    \(line.trimmingCharacters(in: .whitespaces))")
}

print("\n==> stages")
_ = console.wait(for: "ferry-balloon: steady", timeout: 120)
Thread.sleep(forTimeInterval: options.settle)
record("after touch+release")

// Everything touching the VM happens on its own queue: VZVirtualMachine is
// queue-confined, and reading memoryBalloonDevices from anywhere else is
// undefined rather than merely discouraged.
let deviceCount = queue.sync { vm.memoryBalloonDevices.count }
guard deviceCount > 0 else {
    FileHandle.standardError.write("no balloon device on the running VM\n".data(using: .utf8)!)
    exit(1)
}

// Read the request back after writing it. A balloon that never inflates and a
// write that never landed look identical from the host's memory counters, and
// only one of them is a finding about the framework.
let acknowledged = queue.sync { () -> UInt64 in
    guard let balloon = vm.memoryBalloonDevices.first
        as? VZVirtioTraditionalMemoryBalloonDevice else { return 0 }
    balloon.targetVirtualMachineMemorySize = options.targetMiB * 1024 * 1024
    return balloon.targetVirtualMachineMemorySize
}
print("    -- requested \(options.targetMiB) MiB, device reports \(acknowledged / 1024 / 1024) MiB --")
for _ in 0..<4 {
    Thread.sleep(forTimeInterval: options.settle)
    record("shrinking")
}

// Darwin's MADV_FREE keeps pages resident until something else needs them, so
// a host that gave the memory back and a host that did not look identical on an
// idle machine. Asking for memory is the only way to tell them apart: if the
// balloon really released those pages, this allocation should be served partly
// from them and the VM's footprint should fall.
if options.pressureMiB > 0 {
    print("    -- applying \(options.pressureMiB) MiB of host memory pressure --")
    autoreleasepool {
        var hog = [UInt8](repeating: 0, count: options.pressureMiB * 1024 * 1024)
        for i in stride(from: 0, to: hog.count, by: 4096) { hog[i] = 1 }
        record("under pressure")
        hog = []
    }
    Thread.sleep(forTimeInterval: options.settle)
    record("pressure released")
}

queue.sync {
    (vm.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice)?
        .targetVirtualMachineMemorySize = options.memoryMiB * 1024 * 1024
}
print("    -- restored to \(options.memoryMiB) MiB --")
for _ in 0..<2 {
    Thread.sleep(forTimeInterval: options.settle)
    record("restored")
}

let peak = rows.first?.1 ?? 0
let trough = rows.filter { $0.0 == "shrinking" }.map(\.1).min() ?? 0
print("""

==> result
    host footprint before  \(Int(peak)) MiB
    host footprint after   \(Int(trough)) MiB
    reclaimed              \(Int(peak - trough)) MiB
    guest agreed           \(rows.first?.2 ?? -1) MiB -> \(rows.filter { $0.0 == "shrinking" }.last?.2 ?? -1) MiB
""")

queue.sync { vm.stop { _ in } }
Thread.sleep(forTimeInterval: 1)
