// Measures how many Linux virtual machines macOS will run at once, and how
// long one takes to boot.
//
// Both numbers bound the k5s design directly: with one VM per pod, the
// concurrent-VM limit is the pod limit for the whole node, and VM boot time is
// pod start latency. Nothing here uses Apple's Containerization framework --
// this is Virtualization.framework alone, so the answer is a property of the
// operating system rather than of any particular container tool.

import Foundation
import Virtualization

struct Options {
    var kernel = "assets/vmlinux-arm64"
    var initrd = "build/initramfs.cpio"
    var maxVMs = 64
    var memoryMiB: UInt64 = 128
    var cpuCount = 1
    var bootTimeout = 30.0
    var holdSeconds = 0.0
    var network = false
    var disk = false
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
        case "--kernel":   o.kernel = value()
        case "--initrd":   o.initrd = value()
        case "--max":      o.maxVMs = Int(value()) ?? o.maxVMs
        case "--memory":   o.memoryMiB = UInt64(value()) ?? o.memoryMiB
        case "--cpus":     o.cpuCount = Int(value()) ?? o.cpuCount
        case "--timeout":  o.bootTimeout = Double(value()) ?? o.bootTimeout
        case "--hold":     o.holdSeconds = Double(value()) ?? o.holdSeconds
        case "--network":  o.network = true
        case "--disk":     o.disk = true
        default:
            FileHandle.standardError.write("unknown flag \(flag)\n".data(using: .utf8)!)
            exit(2)
        }
    }
    return o
}

/// Watches a VM's console for the marker its init prints, so boot can be timed
/// all the way into guest userspace rather than only to the hypervisor's
/// acknowledgement that it started.
final class ConsoleWatcher {
    private let pipe = Pipe()
    private let marker: String
    private let semaphore = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var fired = false
    private let lock = NSLock()

    init(marker: String) {
        self.marker = marker
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            self.buffer.append(chunk)
            if !self.fired,
               let text = String(data: self.buffer, encoding: .utf8),
               text.contains(self.marker) {
                self.fired = true
                self.semaphore.signal()
            }
        }
    }

    var attachment: VZSerialPortAttachment {
        // The guest only writes; give it a read end it will never see traffic on.
        VZFileHandleSerialPortAttachment(
            fileHandleForReading: Pipe().fileHandleForReading,
            fileHandleForWriting: pipe.fileHandleForWriting)
    }

    func wait(timeout: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }

    func stop() {
        pipe.fileHandleForReading.readabilityHandler = nil
    }
}

func makeConfiguration(_ o: Options, console: ConsoleWatcher?) throws -> VZVirtualMachineConfiguration {
    let config = VZVirtualMachineConfiguration()
    config.cpuCount = o.cpuCount
    config.memorySize = o.memoryMiB * 1024 * 1024

    let bootLoader = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: o.kernel))
    bootLoader.initialRamdiskURL = URL(fileURLWithPath: o.initrd)
    // panic=-1 so a guest that fails to boot dies immediately and is counted as
    // a failure rather than sitting there looking like a healthy VM.
    bootLoader.commandLine = "console=hvc0 panic=-1"
    config.bootLoader = bootLoader

    if let console {
        let port = VZVirtioConsoleDeviceSerialPortConfiguration()
        port.attachment = console.attachment
        config.serialPorts = [port]
    }

    // A real pod needs an interface, and interfaces may be scarcer than VMs.
    // NAT is the attachment available without extra privileges; the routable
    // per-pod addressing this design ultimately wants needs newer vmnet
    // support, but the question here is only how many interfaces can exist.
    if o.network {
        let nic = VZVirtioNetworkDeviceConfiguration()
        nic.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [nic]
    }

    // A real pod also needs a root filesystem. Every VM attaches the same image
    // read-only, which isolates the question of how many block devices can be
    // open from the cost of materialising a rootfs per pod.
    if o.disk {
        let url = URL(fileURLWithPath: "build/rootfs.img")
        let attachment = try VZDiskImageStorageDeviceAttachment(url: url, readOnly: true)
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
    }

    try config.validate()
    return config
}

let options = parseOptions()

for path in [options.kernel, options.initrd] where !FileManager.default.fileExists(atPath: path) {
    FileHandle.standardError.write("missing \(path); run ./build.sh first\n".data(using: .utf8)!)
    exit(1)
}

print("""
==> VM ceiling probe
    kernel   \(options.kernel)
    initrd   \(options.initrd)
    each VM  \(options.cpuCount) cpu, \(options.memoryMiB) MiB\(options.network ? ", 1 nic" : "")\(options.disk ? ", 1 disk" : "")
    ceiling  attempting up to \(options.maxVMs)
""")

let queue = DispatchQueue(label: "k5s.vmceiling")
var running: [VZVirtualMachine] = []
var failure: String?
var bootTimes: [TimeInterval] = []
var guestUpTime: TimeInterval?

for index in 1...options.maxVMs {
    // Only the first VM carries a console; the marker proves guests really
    // reach userspace, and one sample is enough to establish that.
    let watcher = index == 1 ? ConsoleWatcher(marker: "guest userspace up") : nil

    let config: VZVirtualMachineConfiguration
    do {
        config = try makeConfiguration(options, console: watcher)
    } catch {
        failure = "configuration invalid at VM \(index): \(error.localizedDescription)"
        break
    }

    let vm = VZVirtualMachine(configuration: config, queue: queue)
    let started = DispatchSemaphore(value: 0)
    var startError: Error?
    let clock = Date()

    queue.async {
        vm.start { result in
            if case .failure(let error) = result { startError = error }
            started.signal()
        }
    }

    guard started.wait(timeout: .now() + options.bootTimeout) == .success else {
        failure = "VM \(index) did not return from start() within \(Int(options.bootTimeout))s"
        break
    }
    if let startError {
        failure = "VM \(index) failed to start: \(startError.localizedDescription)"
        break
    }

    bootTimes.append(Date().timeIntervalSince(clock))
    running.append(vm)

    if let watcher {
        if watcher.wait(timeout: options.bootTimeout) {
            guestUpTime = Date().timeIntervalSince(clock)
            print(String(format: "    guest reached userspace in %.2fs", guestUpTime!))
        } else {
            print("    warning: first guest never printed its marker; VMs may be starting but not booting")
        }
        watcher.stop()
    }

    if index % 10 == 0 || index <= 5 {
        print(String(format: "    [%3d] running  (start %.3fs, %d MiB committed)",
                     index, bootTimes.last!, UInt64(index) * options.memoryMiB))
    }
}

print("\n===== RESULT =====")
print("concurrent VMs reached : \(running.count)")
if let failure {
    print("stopped because        : \(failure)")
} else {
    print("stopped because        : hit the requested maximum (--max \(options.maxVMs)); the real ceiling is higher")
}
if !bootTimes.isEmpty {
    let total = bootTimes.reduce(0, +)
    print(String(format: "start() latency        : min %.3fs  mean %.3fs  max %.3fs",
                 bootTimes.min()!, total / Double(bootTimes.count), bootTimes.max()!))
}
if let guestUpTime {
    print(String(format: "guest userspace        : %.2fs (first VM, cold)", guestUpTime))
}
print("memory committed       : \(UInt64(running.count) * options.memoryMiB) MiB")
print("==================")

if options.holdSeconds > 0 {
    print("holding \(Int(options.holdSeconds))s...")
    Thread.sleep(forTimeInterval: options.holdSeconds)
}

let drained = DispatchGroup()
for vm in running {
    drained.enter()
    queue.async {
        guard vm.canRequestStop || vm.state == .running else { drained.leave(); return }
        vm.stop { _ in drained.leave() }
    }
}
_ = drained.wait(timeout: .now() + 30)
