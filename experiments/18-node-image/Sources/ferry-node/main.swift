// Builds a node image into a disk, and boots it as a machine.
//
// This is the seed of what docs/MACHINES.md calls ferry-machined. It does the
// two things a Machine controller would do for each node -- turn an image into
// a root filesystem, and start a VM with an address and a way to join -- with
// the decisions on the command line instead of in a custom resource.
//
// Deliberately not a pod: the VM boots its own init, owns a writable /proc, and
// has a disk of its own size. Experiment 17 ran the node's software inside a
// ferry-cri pod and met four separate walls that exist only because a container
// is not a machine.

import Containerization
import ContainerizationEXT4
import ContainerizationOCI
import ContainerizationExtras
import Foundation
import SystemPackage
import Virtualization

// Unbuffered: this process is usually watched through a log file, and a block
// buffer means a successful boot looks exactly like a silent hang.
setvbuf(stdout, nil, _IONBF, 0)

let platform = ContainerizationOCI.Platform(arch: "arm64", os: "linux", variant: "v8")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("ferry-node: \(message)\n".data(using: .utf8)!)
    exit(1)
}

func option(_ name: String, _ fallback: String? = nil) -> String {
    let args = Array(CommandLine.arguments.dropFirst())
    if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
    if let fallback { return fallback }
    fail("missing \(name)")
}

// MARK: - build

/// Unpacks an OCI layout into an ext4 filesystem a VM can boot from.
///
/// The image is built with Docker because that is the tooling everyone has;
/// what a VM needs is a disk, and this is the conversion between them.
func build() async throws {
    let layout = option("--layout")
    let out = option("--out")
    let sizeGiB = UInt64(option("--size-gib", "8")) ?? 8

    let store = try ImageStore(path: URL(filePath: option("--store", NSTemporaryDirectory() + "ferry-node-store")))
    let images = try await store.load(from: URL(filePath: layout))
    guard let image = images.first else { fail("no images in \(layout)") }
    print("==> image \(image.reference)")

    try? FileManager.default.removeItem(atPath: out)
    // Generous on purpose: the file is sparse, so the disk costs what the node
    // writes rather than what it may hold, and a node that runs out of root
    // filesystem reports DiskPressure and evicts everything on it.
    let mount = try await EXT4Unpacker(capacityInBytes: sizeGiB * 1024 * 1024 * 1024)
        .unpack(image, for: platform, at: URL(filePath: out))
    print("==> disk \(mount.source)")

    let attributes = try FileManager.default.attributesOfItem(atPath: out)
    let apparent = (attributes[.size] as? UInt64) ?? 0
    print("    \(apparent / 1024 / 1024) MiB apparent")
}

// MARK: - run

/// Boots the node and leaves it running.
func run() throws {
    let disk = option("--disk")
    let kernelPath = option("--kernel")
    let nodeName = option("--node-name", "ferry-node-1")
    let apiServer = option("--api-server")
    let token = option("--token")
    let caPath = option("--ca")
    let cpus = Int(option("--cpus", "2")) ?? 2
    let memoryMiB = UInt64(option("--memory-mib", "2048")) ?? 2048
    let podCIDR = option("--pod-cidr", "10.88.0.0/16")
    let taintsOption = option("--taints", "").split(separator: ",").map(String.init)
    // The kubelet has to know where cluster DNS lives before any pod starts, and
    // it cannot be discovered -- the address is a ClusterIP chosen by the
    // cluster, so the machine is simply told.
    let clusterDNS = option("--cluster-dns", "10.96.0.10")

    guard #available(macOS 26.0, *) else { fail("vmnet addressing needs macOS 26") }

    // Per-node configuration arrives on a second disk rather than in the image:
    // the image is the same for every node, and the certificate authority it
    // must trust is not. This is a config drive by another name, and it is also
    // where a Machine controller would put anything else a node needs to be
    // told once.
    let configDisk = disk + ".config.ext4"
    try makeConfigDisk(caPath: caPath, out: configDisk)

    // An address of its own, on ferry's own network, so the Mac can reach the
    // kubelet -- which is what kubectl logs and exec need -- and the node can
    // reach the API server.
    //
    // --subnet asks for a named network rather than whichever one vmnet hands
    // out. Two machines on one subnet is what pod-to-pod traffic between nodes
    // will need, and whether two processes may share one is the question
    // milestone 3 turns on.
    let requestedSubnet = option("--subnet", "")
    var network = try VmnetNetwork(
        subnet: requestedSubnet.isEmpty ? nil : try CIDRv4(requestedSubnet))
    guard let interface = try network.createInterface(nodeName) as? VmnetNetwork.Interface else {
        fail("vmnet gave no interface")
    }
    let address = "\(interface.ipv4Address)"
    let gateway = interface.ipv4Gateway.map { "\($0)" } ?? ""
    print("==> \(nodeName) at \(address), gateway \(gateway)")

    // A controller needs the address this machine was given, and parsing it out
    // of a log line is the kind of coupling that breaks quietly. Written as
    // JSON, once, before the machine is started.
    if case let statusPath = option("--status-file", ""), !statusPath.isEmpty {
        let status: [String: String] = [
            "name": nodeName, "address": address, "gateway": gateway,
            "podCIDR": podCIDR, "clusterDNS": clusterDNS,
        ]
        if let body = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted]) {
            try? body.write(to: URL(filePath: statusPath))
        }
    }

    let console = Console()
    let config = try machineConfiguration(
        nodeName: nodeName, disk: disk, configDisk: configDisk, kernelPath: kernelPath,
        cpus: cpus, memoryMiB: memoryMiB, apiServer: apiServer, token: token,
        address: address, gateway: gateway, podCIDR: podCIDR, clusterDNS: clusterDNS,
        taints: taintsOption, interface: interface, console: console)

    let queue = DispatchQueue(label: "ferry.node")
    let vm = VZVirtualMachine(configuration: config, queue: queue)
    let started = DispatchSemaphore(value: 0)
    let failure = Box<Error?>(nil)
    let clock = Date()
    queue.async {
        vm.start { result in
            if case .failure(let error) = result { failure.value = error }
            started.signal()
        }
    }
    guard started.wait(timeout: .now() + 60) == .success, failure.value == nil else {
        // The framework's message for a bad configuration names the category and
        // not the device, so print what it hands back underneath.
        if let error = failure.value as NSError? {
            fail("failed to start: \(error.localizedDescription) [\(error.domain) \(error.code)] \(error.userInfo)")
        }
        fail("failed to start: timed out")
    }
    print("==> started in \(String(format: "%.2f", Date().timeIntervalSince(clock)))s")

    // The node says so itself, on the console, and the host prints it as it
    // arrives -- a machine that fails to join should say why without anyone
    // having to attach to it.
    // FERRY_NODE_VERBOSE prints the guest's whole console, kernel included,
    // which is the only way to see why a machine that never registers did not.
    let verbose = ProcessInfo.processInfo.environment["FERRY_NODE_VERBOSE"] != nil
    console.onLine = { line in
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if verbose || text.contains("ferry-node:") { print("    \(text)") }
    }

    if CommandLine.arguments.contains("--wait-registered") {
        if console.wait(for: "ferry-node: registered", timeout: 300) {
            print("==> registered after \(String(format: "%.2f", Date().timeIntervalSince(clock)))s")
        } else {
            print("==> never registered")
        }
    }

    // Hold the machine up; the caller stops the process when it is done.
    while true { sleep(3600) }
}

/// Everything a machine is, in one place, so `run` and `serve` cannot drift
/// apart on what a node boots with.
@available(macOS 26.0, *)
func machineConfiguration(
    nodeName: String, disk: String, configDisk: String, kernelPath: String,
    cpus: Int, memoryMiB: UInt64, apiServer: String, token: String,
    address: String, gateway: String, podCIDR: String, clusterDNS: String,
    clusterCIDR: String = "",
    taints: [String] = [],
    interface: VmnetNetwork.Interface, console: Console,
    podNIC: MachineNIC? = nil
) throws -> VZVirtualMachineConfiguration {
    let config = VZVirtualMachineConfiguration()
    config.cpuCount = cpus
    config.memorySize = memoryMiB * 1024 * 1024

    let boot = VZLinuxBootLoader(kernelURL: URL(filePath: kernelPath))
    // Everything the node needs to join, on the command line: there is no other
    // channel at first boot that does not mean building a second device.
    var arguments = [
        "console=hvc0", "root=/dev/vda", "rw", "init=/sbin/ferry-init",
        "ferry.node=\(nodeName)",
        "ferry.api=\(apiServer)",
        "ferry.token=\(token)",
        "ferry.address=\(address)",
        "ferry.gateway=\(gateway)",
        "ferry.podcidr=\(podCIDR)",
        "ferry.dnssvc=\(clusterDNS)",
        // The prefix mode 1's pods treat as on-link. A machine's own slice is a
        // /24 it learns from the API, but the segment it shares with those pods
        // is the whole cluster CIDR, and nothing in the guest can derive one
        // from the other.
        "ferry.clustercidr=\(clusterCIDR)",
    ]
    // Only when there are some. An empty `ferry.taints=` reaches the guest as a
    // parameter that is set but blank, and `--register-with-taints=""` is an
    // error rather than a no-op -- a kubelet that will not start at all.
    //
    // Comma-separated because a space would end this parameter and begin a
    // kernel argument. That is also the kubelet's own spelling, so the string
    // travels from the Machine spec to the flag without being re-parsed
    // anywhere in between.
    if !taints.isEmpty {
        arguments.append("ferry.taints=\(taints.joined(separator: ","))")
    }
    boot.commandLine = arguments.joined(separator: " ")
    config.bootLoader = boot

    // vda is the node, vdb is its configuration.
    // The two-argument initializer defaults synchronizationMode to .full, which
    // turns every fsync in the guest into a full host barrier. containerd's
    // metadata store is bbolt -- a single writer that fsyncs each transaction --
    // so twenty concurrent RunPodSandbox calls queue on that one lock and each
    // waits out a barrier. Profiling a burst showed ten goroutines parked on
    // core/metadata's mutex with another inside a syscall, while the guest used
    // 48% of one core out of ten.
    let rootAttachment = try VZDiskImageStorageDeviceAttachment(
        url: URL(filePath: disk), readOnly: false,
        cachingMode: .automatic, synchronizationMode: .fsync)
    config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: rootAttachment)]
    if ProcessInfo.processInfo.environment["FERRY_NODE_NO_CONFIG"] == nil {
        let configAttachment = try VZDiskImageStorageDeviceAttachment(
            url: URL(filePath: configDisk), readOnly: true)
        config.storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: configAttachment))
    }
    // eth0 is vmnet: the internet, the Mac, the API server, and pod traffic to
    // every other machine on this network.
    //
    // eth1, when there is one, is ferry's pod network -- the flat segment mode
    // 1's pods live on. It is a plain datagram socket rather than a vmnet
    // interface, because vmnet is exactly what cannot carry this: it will not
    // route between its own networks, so a machine and a pod VM on two of them
    // have no path however the Mac is configured.
    //
    // The order is load bearing. The guest names these eth0 and eth1 in the
    // order they are attached, and its init configures them by those names.
    config.networkDevices = [try interface.device()]
    if let podNIC {
        config.networkDevices.append(podNIC.device())
    }

    let port = VZVirtioConsoleDeviceSerialPortConfiguration()
    port.attachment = console.attachment
    config.serialPorts = [port]

    // Without this the guest has no entropy source at all -- rng_available is
    // empty -- so the kernel seeds its CRNG from interrupt timing alone and
    // reports `random: crng init done` about ten seconds in. Until that moment
    // every getrandom(2) blocks, which in practice means every Go binary that
    // wants randomness: the kubelet's TLS bootstrap, and `ctr`, which was
    // measured taking seventeen seconds to answer `version` against a
    // containerd that had booted in forty-five milliseconds. It is one line and
    // it moves the whole early boot.
    config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

    try config.validate()
    return config
}

/// A one-file filesystem carrying what this particular node has to be told.
///
/// The node image is identical for every machine; the cluster's certificate
/// authority is not, and it is too big for a kernel command line that also has
/// to carry everything else. So it travels on its own disk, which is built from
/// scratch here -- the ext4 formatter makes filesystems, it does not edit them.
///
/// Small, read-only, and thrown away with the node.
func makeConfigDisk(caPath: String, out: String) throws {
    let ca = try Data(contentsOf: URL(filePath: caPath))
    try? FileManager.default.removeItem(atPath: out)
    let formatter = try EXT4.Formatter(FilePath(out), minDiskSize: 16.mib())
    // Opened first: an InputStream reads nothing until it is, and a silently
    // empty certificate looks exactly like a node that cannot trust the cluster.
    let stream = InputStream(data: ca)
    stream.open()
    defer { stream.close() }
    try formatter.create(path: FilePath("/ca.crt"), mode: UInt16(EXT4.Inode.Mode(.S_IFREG, 0o644)),
                         buf: stream)
    try formatter.close()
    print("==> config disk \(out) carries \(ca.count) bytes of CA")
}

/// A reference cell, so a completion handler can report back out of a closure
/// that may not capture a mutable variable.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// The guest's console, collected so the host can watch for markers.
///
/// Unchecked because every field is behind the lock; the readability handler
/// runs on whatever queue the file handle chooses.
final class Console: @unchecked Sendable {
    private let pipe = Pipe()
    private let lock = NSLock()
    private var text = ""
    private var waiting: (marker: String, semaphore: DispatchSemaphore)?
    private var lineHandler: (@Sendable (String) -> Void)?

    var onLine: (@Sendable (String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return lineHandler }
        set { lock.lock(); lineHandler = newValue; lock.unlock() }
    }

    init() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            guard !chunk.isEmpty, let piece = String(data: chunk, encoding: .utf8) else { return }
            self.lock.lock()
            self.text += piece
            let waiting = self.waiting
            let hit = waiting.map { self.text.contains($0.marker) } ?? false
            if hit { self.waiting = nil }
            let handler = self.lineHandler
            self.lock.unlock()
            for line in piece.split(separator: "\n") { handler?(String(line)) }
            if hit, let waiting { waiting.semaphore.signal() }
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
        if text.contains(marker) { lock.unlock(); return true }
        waiting = (marker, semaphore)
        lock.unlock()
        return semaphore.wait(timeout: .now() + timeout) == .success
    }
}

// MARK: - entry

switch CommandLine.arguments.dropFirst().first {
// Caught rather than thrown out of main: an uncaught error here traps with a
// Swift stack trace, and "failed to create vmnet network with status 1001"
// reads much better than a crash when the real answer is that another process
// already holds that subnet.
case "build":
    do { try await build() } catch { fail("build: \(error)") }
case "run":
    do { try run() } catch { fail("run: \(error)") }
case "serve":
    if #available(macOS 26.0, *) {
        do { try serve() } catch { fail("serve: \(error)") }
    } else {
        fail("serve needs macOS 26")
    }
default:
    print("""
    usage:
      ferry-node build --layout <oci-dir> --out <disk.ext4> [--size-gib 8]
      ferry-node serve --dir <machines-dir> --kernel <vmlinux> --ca <ca.crt> \\
                       --api-server <url> [--subnet 192.168.200.0/24]
      ferry-node run   --disk <disk.ext4> --kernel <vmlinux> --ca <ca.crt> \\
                       --api-server <url> --token <id.secret> [--node-name n] \\
                       [--cpus 2] [--memory-mib 2048] [--wait-registered]
    """)
    exit(2)
}
