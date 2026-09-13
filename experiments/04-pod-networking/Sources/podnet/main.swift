// Probes the per-pod networking model: can a vmnet network hand out routable
// addresses, and is a pod VM holding one reachable from the Mac?
//
// Stage 1 (--network-only) creates the network and allocates addresses. It
// answers the privilege question on its own, since vmnet_network_create is the
// call most likely to require elevation.

import Containerization
import ContainerizationEXT4
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import SystemPackage

// Unbuffered: this program can be killed mid-run (VM subsystem failures show
// up as SIGKILL), and a buffered stdout loses exactly the output that says how
// far it got.
setvbuf(stdout, nil, _IONBF, 0)

let args = Array(CommandLine.arguments.dropFirst())
let networkOnly = args.contains("--network-only")
let count = args.firstIndex(of: "--count").flatMap { Int(args[safe: $0 + 1] ?? "") } ?? 4
let subnetText = args.firstIndex(of: "--subnet").flatMap { args[safe: $0 + 1] } ?? "192.168.66.1/24"

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

print("==> ferry pod networking probe")
print("    euid    \(getuid() == 0 ? "0 (root)" : String(getuid()))")
print("    subnet  \(subnetText)")

let subnet: CIDRv4
do {
    subnet = try CIDRv4(subnetText)
} catch {
    fail("bad subnet \(subnetText): \(error)")
}

var network: VmnetNetwork
do {
    network = try VmnetNetwork(subnet: subnet)
} catch {
    // This is the call that needs privilege. Report it plainly rather than
    // letting it look like a generic framework failure.
    fail("""
        failed to create vmnet network: \(error)

        vmnet_network_create is the privileged step. If this failed as a normal
        user, rerun under sudo to find out whether elevation is the whole story
        or an entitlement is also required.
        """)
}

print("    gateway \(network.ipv4Gateway)  (this Mac)")
print("    actual  \(network.subnet)")
print("\n==> allocating \(count) pod addresses")

var allocated: [(id: String, addr: String)] = []
for i in 1...count {
    let id = "pod-\(i)"
    do {
        guard let iface = try network.createInterface(id) else {
            fail("createInterface returned nil for \(id)")
        }
        allocated.append((id, "\(iface.ipv4Address)"))
        print("    \(id.padding(toLength: 10, withPad: " ", startingAt: 0)) \(iface.ipv4Address)  gw \(iface.ipv4Gateway.map { "\($0)" } ?? "-")")
    } catch {
        fail("allocation failed at \(id): \(error)")
    }
}

// Release one and re-allocate, to show the allocator actually recycles rather
// than simply counting upward -- pod churn depends on it.
if let first = allocated.first {
    try? network.releaseInterface(first.id)
    if let reused = try? network.createInterface("pod-recycled") {
        print("\n    released \(first.id) (\(first.addr)), reallocated as \(reused.ipv4Address)")
    }
}

print("\n===== RESULT =====")
print("vmnet network  : created")
print("gateway        : \(network.ipv4Gateway)")
print("addresses      : \(allocated.count) allocated from \(network.subnet)")
print("==================")

if networkOnly {
    print("\n--network-only: stopping before booting a pod")
    exit(0)
}

// ---------------------------------------------------------------- stage 2
// Boot a real pod on one of those addresses and see whether the Mac can reach
// it. An allocated address that nothing answers on would prove nothing.

let stateDir = URL(filePath: args.firstIndex(of: "--state").flatMap { args[safe: $0 + 1] } ?? "/tmp/ferry-e04")
let kernelPath = args.firstIndex(of: "--kernel").flatMap { args[safe: $0 + 1] }
    ?? "../03-vm-ceiling/assets/vmlinux-arm64"
let holdSeconds = args.firstIndex(of: "--hold").flatMap { Double(args[safe: $0 + 1] ?? "") } ?? 0

guard FileManager.default.fileExists(atPath: kernelPath) else {
    fail("no kernel at \(kernelPath); run ../03-vm-ceiling/fetch-kernel.sh")
}
try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

let platform = ContainerizationOCI.Platform(arch: "arm64", os: "linux", variant: "v8")
let store = try ImageStore(path: stateDir)

print("\n==> preparing guest images (first run pulls, later runs reuse)")

// vminit is the guest agent the framework talks to over vsock. Pin it to the
// same release as the framework so host and guest cannot drift.
let initImage = try await store.getInitImage(reference: "ghcr.io/apple/containerization/vminit:0.45.0")
let initPath = stateDir.appending(component: "init.ext4")
let initfs: Containerization.Mount
do {
    initfs = try await initImage.initBlock(at: initPath, for: .linuxArm)
} catch let error as ContainerizationError where error.code == .exists {
    initfs = .block(format: "ext4", source: initPath.path(), destination: "/", options: ["ro"])
}
print("    initfs  \(initPath.lastPathComponent)")

let appImage = try await store.pull(reference: "ghcr.io/linuxcontainers/alpine:3.20", platform: platform)
let rootfsPath = stateDir.appending(component: "alpine.ext4")
let rootfs: Containerization.Mount
do {
    rootfs = try await EXT4Unpacker(capacityInBytes: 1.gib()).unpack(appImage, for: platform, at: rootfsPath)
} catch let error as ContainerizationError where error.code == .exists {
    rootfs = .block(format: "ext4", source: rootfsPath.path(), destination: "/", options: [])
}
print("    rootfs  \(rootfsPath.lastPathComponent)  (alpine 3.20)")

guard let podInterface = try network.createInterface("ferry-pod") else {
    fail("could not allocate an address for the pod")
}
let podIP = "\(podInterface.ipv4Address)".split(separator: "/").first.map(String.init) ?? ""
print("\n==> booting pod at \(podIP)")

let kernel = Kernel(path: URL(filePath: kernelPath), platform: .linuxArm)
let vmm = VZVirtualMachineManager(kernel: kernel, initialFilesystem: initfs)

let pod = try LinuxPod("ferry-pod", vmm: vmm) { config in
    config.cpus = 2
    config.memoryInBytes = 512.mib()
    config.interfaces = [podInterface]
    config.hostname = "ferry-pod"
}

try await pod.addContainer("app", rootfs: rootfs) { config in
    // Alpine has no long-running entrypoint; keep PID 1 alive so the pod stays
    // up long enough to be probed from the host.
    config.process.arguments = ["/bin/sh", "-c", "ip -4 addr show; sleep 3600"]
}

let bootClock = Date()
try await pod.create()
try await pod.startContainer("app")
let bootSeconds = Date().timeIntervalSince(bootClock)
print(String(format: "    pod up in %.2fs", bootSeconds))

// The guest configures its interface during boot, so give it a moment before
// declaring the address unreachable.
func ping(_ host: String, timeoutSeconds: Int) -> (ok: Bool, output: String) {
    let proc = Process()
    proc.executableURL = URL(filePath: "/sbin/ping")
    proc.arguments = ["-c", "3", "-W", "1000", "-t", "\(timeoutSeconds)", host]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    do { try proc.run() } catch { return (false, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return (proc.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
}

print("\n==> probing \(podIP) from macOS")
var reachable = false
var pingOutput = ""
for attempt in 1...10 {
    let result = ping(podIP, timeoutSeconds: 2)
    if result.ok {
        reachable = true
        pingOutput = result.output
        print("    reachable on attempt \(attempt)")
        break
    }
    pingOutput = result.output
    try? await Task.sleep(for: .seconds(1))
}

// ---------------------------------------------------------------- stage 3
// Host-to-pod is only half of it. Kubernetes assumes any pod can reach any
// other pod directly, so boot a second pod and have it ping the first. Its
// exit status is the answer -- no parsing, no guessing.
var podToPod: String = "skipped"
if !args.contains("--no-pod-to-pod") {
    print("\n==> second pod, pinging the first")
    guard let peerInterface = try network.createInterface("ferry-peer") else {
        fail("could not allocate an address for the peer pod")
    }
    let peerIP = "\(peerInterface.ipv4Address)".split(separator: "/").first.map(String.init) ?? ""
    print("    peer at \(peerIP)")

    let peerRootfsPath = stateDir.appending(component: "alpine-peer.ext4")
    try? FileManager.default.removeItem(at: peerRootfsPath)
    let peerRootfs = try rootfs.clone(to: peerRootfsPath.path())

    let peerVMM = VZVirtualMachineManager(kernel: kernel, initialFilesystem: initfs)
    let peer = try LinuxPod("ferry-peer", vmm: peerVMM) { config in
        config.cpus = 2
        config.memoryInBytes = 512.mib()
        config.interfaces = [peerInterface]
        config.hostname = "ferry-peer"
    }
    try await peer.addContainer("probe", rootfs: peerRootfs) { config in
        config.process.arguments = ["/bin/ping", "-c", "3", "-W", "2", podIP]
    }
    try await peer.create()
    try await peer.startContainer("probe")

    let status = try await peer.waitContainer("probe", timeoutInSeconds: 30)
    podToPod = status.exitCode == 0 ? "YES" : "NO (exit \(status.exitCode))"
    print("    \(peerIP) -> \(podIP): \(podToPod)")

    try await peer.stop()
    try? network.releaseInterface("ferry-peer")
}

print("\n===== RESULT =====")
print("vmnet gateway  : \(network.ipv4Gateway)  (this Mac)")
print("pod address    : \(podIP)")
print("pod -> pod     : \(podToPod)")
print(String(format: "pod boot       : %.2fs", bootSeconds))
print("reachable      : \(reachable ? "YES" : "NO")")
if !pingOutput.isEmpty {
    for line in pingOutput.split(separator: "\n").prefix(6) { print("    \(line)") }
}
print("==================")

if holdSeconds > 0 {
    print("\nholding \(Int(holdSeconds))s (try: ping \(podIP))")
    try? await Task.sleep(for: .seconds(holdSeconds))
}

try await pod.stop()
try? network.releaseInterface("ferry-pod")
exit(reachable ? 0 : 1)
