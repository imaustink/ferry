// Does a unix socket on the Mac reach a process inside a pod VM?
//
// Every device-shaped thing on ferry is frozen at boot, because
// Virtualization.framework cannot hotplug. A socket relay is the exception:
// Containerization carries one over the pod's existing vsock device, so the
// host can hand a pod a file descriptor to something that only macOS can do --
// Metal being the case that prompted this. See docs/GPU.md.
//
// The claim under test is narrow and entirely about plumbing: a unix socket
// this process owns on the host appears at a path inside the container, and
// bytes written to it there arrive here and come back. So the host end is an
// echo server that upper-cases what it is given, and the guest end is the
// smallest client that can speak AF_UNIX. If FERRY goes in and FERRY comes
// back out, nothing was relayed; the answer has to be FERRY -> FERRY in
// capitals, which only this process can produce.

import Containerization
import ContainerizationEXT4
import ContainerizationError
import ContainerizationOCI
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String, _ fallback: String) -> String {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return fallback }
    return args[i + 1]
}

// macOS caps a unix socket path near 104 bytes, and the guest stages the relay
// under a path of its own, so the state directory is kept short deliberately.
let stateDir = URL(filePath: option("--state", "/tmp/ferry-relayprobe"))
let kernelPath = option("--kernel", "../03-vm-ceiling/assets/vmlinux-arm64")
let initImage = option("--init-image", "ghcr.io/apple/containerization/vminit:0.45.0")
// python because it is the smallest image with an AF_UNIX client in it. busybox
// nc cannot do unix sockets, and the point is to test the relay, not to ship a
// guest binary -- a real workload would already speak whatever ferry-gpud does.
// Fully qualified: the store takes references as written, and ferry-cri's own
// normalization lives in the runtime, not here.
let image = option("--image", "docker.io/library/python:3.12-alpine")
// The destination inside the container. Nothing creates it beforehand: whether
// a bind mount to a path that does not exist works is part of what this asks.
let destination = option("--destination", "/run/ferry/gpu.sock")

let probe = "ferry"
let expected = probe.uppercased()

// With --gpu-socket, the thing relayed in is a real ferry-gpud pod socket
// rather than this probe's echo server, and the guest asks the Mac's GPU for
// work instead of for capitals. Same relay either way: the point of the flag is
// that ferry-gpud needs no knowledge of any of this.
let gpuSocket = option("--gpu-socket", "")
let gpuMode = !gpuSocket.isEmpty

guard FileManager.default.fileExists(atPath: kernelPath) else {
    FileHandle.standardError.write(
        "no kernel at \(kernelPath); run experiments/03-vm-ceiling/fetch-kernel.sh\n".data(using: .utf8)!)
    exit(1)
}
try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
let hostSocket = gpuMode ? URL(filePath: gpuSocket) : stateDir.appending(component: "gpu.sock")

if gpuMode {
    guard FileManager.default.fileExists(atPath: gpuSocket) else {
        FileHandle.standardError.write(Data("""
            no socket at \(gpuSocket)
            ask ferry-gpud for one first:
              curl --unix-socket /tmp/ferry-gpud.sock -XPOST http://l/pods -d '{"uid":"probe"}'

            """.utf8))
        exit(1)
    }
}

print("==> relay probe\(gpuMode ? " (ferry-gpud)" : "")")
print("    kernel      \(kernelPath)")
print("    image       \(image)")
print("    host socket \(hostSocket.path())")
print("    in guest    \(destination)")

// MARK: - The host end

/// Upper-cases whatever it is given, and remembers that it was asked.
///
/// Deliberately not an HTTP server: the design in docs/GPU.md puts a protocol
/// here, and a protocol would make a failure ambiguous between the relay and
/// the framing.
final class EchoServer: @unchecked Sendable {
    private let path: String
    private let lock = NSLock()
    private var seen: [String] = []

    init(path: String) { self.path = path }

    /// What arrived from the guest, in order.
    var received: [String] { lock.withLock { seen } }

    func start() throws {
        unlink(path)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw Failure("could not create \(path)") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw Failure("socket path is too long: \(path)")
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
        guard bound == 0, listen(listener, 4) == 0 else {
            Darwin.close(listener)
            throw Failure("could not listen on \(path)")
        }

        Thread.detachNewThread { [self] in
            while true {
                let accepted = accept(listener, nil, nil)
                if accepted < 0 { continue }
                Thread.detachNewThread { [self] in serve(accepted) }
            }
        }
    }

    private func serve(_ descriptor: Int32) {
        defer { Darwin.close(descriptor) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { return }
            let text = String(decoding: buffer[0..<count], as: UTF8.self)
            lock.withLock { seen.append(text) }
            print("    host <- guest: \(text.debugDescription)")
            let reply = Array(text.uppercased().utf8)
            _ = reply.withUnsafeBufferPointer { write(descriptor, $0.baseAddress, $0.count) }
        }
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Container output, tagged so guest and host lines cannot be confused, and
/// kept so the verdict can be drawn from what the containers actually said.
final class TaggedWriter: Writer, @unchecked Sendable {
    private let tag: String
    private let lock = NSLock()
    private var captured: [String] = []

    init(_ tag: String) { self.tag = tag }

    var lines: [String] { lock.withLock { captured } }

    func write(_ data: Data) throws {
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            print("    \(tag) \(line)")
            lock.withLock { captured.append(String(line)) }
        }
    }
    func close() throws {}
}

let echo = EchoServer(path: hostSocket.path())
if gpuMode {
    print("    serving     ferry-gpud (this probe only relays it)")
} else {
    try echo.start()
    print("    listening")
}

// MARK: - The pod

let store = try ImageStore(path: stateDir)
let platform = ContainerizationOCI.Platform(arch: "arm64", os: "linux", variant: "v8")

print("==> guest agent")
let initfsPath = stateDir.appending(component: "init.ext4")
let initfs: Containerization.Mount
do {
    initfs = try await store.getInitImage(reference: initImage).initBlock(at: initfsPath, for: .linuxArm)
} catch let error as ContainerizationError where error.code == .exists {
    initfs = .block(format: "ext4", source: initfsPath.path(), destination: "/", options: ["ro"])
}

print("==> image \(image)")
let pulled = try await store.pull(reference: image, platform: platform)
let rootfsPath = stateDir.appending(component: "rootfs.ext4")
let rootfs: Containerization.Mount
do {
    rootfs = try await EXT4Unpacker(capacityInBytes: 2 * 1024 * 1024 * 1024)
        .unpack(pulled, for: platform, at: rootfsPath)
} catch let error as ContainerizationError where error.code == .exists {
    rootfs = .block(format: "ext4", source: rootfsPath.path(), destination: "/", options: [])
}

// No network interface at all. If this works, the relay owes nothing to the pod
// network -- which is the argument for using it rather than a TCP listener on
// the pod gateway.
let kernel = Kernel(path: URL(filePath: kernelPath), platform: .linuxArm)
let pod = try LinuxPod("relayprobe", vmm: VZVirtualMachineManager(kernel: kernel, initialFilesystem: initfs)) { c in
    c.cpus = 2
    c.memoryInBytes = 512 * 1024 * 1024
    c.hostname = "relayprobe"
}

let echoClient = """
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect("\(destination)")
s.sendall(b"\(probe)")
got = s.recv(64).decode()
print("sent \(probe), got " + got)
sys.exit(0 if got == "\(expected)" else 2)
"""

// The same thing a real workload would do: HTTP over the socket ferry handed
// it. Nothing here knows it is in a VM, and nothing on the host end knows the
// caller is not a local process.
let gpuClient = """
import http.client, json, socket, sys

class UnixConnection(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(120)
        self.sock.connect("\(destination)")

def call(method, path, payload=None):
    c = UnixConnection("localhost")
    body = json.dumps(payload) if payload is not None else None
    c.request(method, path, body=body, headers={"Content-Type": "application/json"})
    r = c.getresponse()
    return r.status, json.loads(r.read().decode())

status, device = call("GET", "/v1/device")
print("device: " + device.get("name", "?") + " (" + device.get("architecture", "?") + ")")

status, mm = call("POST", "/v1/matmul", {"size": 2048, "iterations": 20})
if status != 200:
    print("matmul failed: " + str(mm)); sys.exit(2)
print("matmul: %dx%d x%d -> %.0f GFLOP/s in %.3fs (checksum %.4f)" % (
    mm["size"], mm["size"], mm["iterations"], mm["gflops"], mm["seconds"], mm["checksum"]))

status, model = call("GET", "/v1/model")
if model.get("available"):
    status, gen = call("POST", "/v1/generate",
                       {"prompt": "In one sentence: why is a VM per pod unusual?",
                        "maxTokens": 60})
    if status != 200:
        print("generate failed: " + str(gen)); sys.exit(2)
    print("generated in %.2fs: %s" % (gen["seconds"], gen["content"].strip()))
else:
    print("on-device model unavailable: " + str(model.get("reason")))

sys.exit(0)
"""

let client = gpuMode ? gpuClient : echoClient

// A writable clone, not the unpacked image itself. Creating a bind mount's
// destination writes into the container's root filesystem, so a container given
// the cached unpack leaves its mount points behind in it -- and the next
// container to clone that image inherits them, which reads exactly like the
// relay having leaked. ferry-cri already clones per container (PodRuntime.swift:727).
let probeRootfsPath = stateDir.appending(component: "probe.ext4").path()
try? FileManager.default.removeItem(atPath: probeRootfsPath)
let probeRootfs = try rootfs.clone(to: probeRootfsPath)

let probeOutput = TaggedWriter("guest:")
try await pod.addContainer("probe", rootfs: probeRootfs) { c in
    c.process.arguments = ["python3", "-c", client]
    c.process.stdout = probeOutput
    c.process.stderr = TaggedWriter("guest!")
    // The whole experiment, in one property.
    c.sockets = [
        UnixSocketConfiguration(
            source: hostSocket,
            destination: URL(filePath: destination),
            direction: .into)
    ]
}

// A second container in the same pod that asks for nothing. Containers in a pod
// share a kernel and a network stack, so if the relay were pod-wide rather than
// per container this one would find the socket too -- and the design's claim
// that a GPU is granted to a container rather than leaked to its sidecars would
// be wrong. It reports what it sees and never fails: the verdict is below.
// Seeing a path and being able to use it are different findings, so it reports
// both: what the inode is, and what happens when it connects.
let sidecarCheck = """
import os, socket, stat
path = "\(destination)"
exists = os.path.exists(path)
kind = "absent"
if exists:
    mode = os.stat(path).st_mode
    kind = "socket" if stat.S_ISSOCK(mode) else ("dir" if stat.S_ISDIR(mode) else "file")
print("sidecar sees " + path + ": " + str(exists) + " (" + kind + ")")
reached = "no"
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect(path)
    s.sendall(b"sidecar")
    reached = s.recv(64).decode()
except Exception as e:
    reached = "refused: " + type(e).__name__
print("sidecar connect: " + reached)
"""

// Its own writable clone: two containers cannot share one ext4 block device.
let sidecarRootfsPath = stateDir.appending(component: "sidecar.ext4").path()
try? FileManager.default.removeItem(atPath: sidecarRootfsPath)
let sidecarRootfs = try rootfs.clone(to: sidecarRootfsPath)

let sidecarOutput = TaggedWriter("side:")
try await pod.addContainer("sidecar", rootfs: sidecarRootfs) { c in
    c.process.arguments = ["python3", "-c", sidecarCheck]
    c.process.stdout = sidecarOutput
    c.process.stderr = TaggedWriter("side!")
}

print("==> booting")
let bootStart = Date()
try await pod.create()
print("    booted in \(String(format: "%.2f", Date().timeIntervalSince(bootStart)))s")

try await pod.startContainer("probe")
let status = try await pod.waitContainer("probe", timeoutInSeconds: 60)

try await pod.startContainer("sidecar")
_ = try? await pod.waitContainer("sidecar", timeoutInSeconds: 60)

try? await pod.stop()

// MARK: - The verdict

print("==> result")
// In GPU mode the host end is ferry-gpud, which this probe does not observe, so
// the evidence of a round trip is what the container printed.
let received = echo.received.joined()
let relayed = gpuMode
    ? probeOutput.lines.contains { $0.hasPrefix("device:") }
    : received.contains(probe)
let returned = status.exitCode == 0

// The sidecar asked for nothing, so the socket must not be there. An absent
// answer is not a pass: if the container failed to run at all it proves nothing.
let sidecarAnswered = sidecarOutput.lines.contains { $0.contains("sidecar sees") }
// Absent is the pass. A path that exists but refuses a connection is not: it
// would mean a mount point was left somewhere the next container can inherit.
let sidecarScoped = sidecarOutput.lines.contains { $0.contains("sidecar sees") && $0.contains(": False") }

print("    guest reached the host socket : \(relayed ? "yes" : "no")")
print("    guest saw the host's answer   : \(returned ? "yes" : "no")")
print("    container exit code           : \(status.exitCode)")
print("    sidecar was denied the socket : \(sidecarAnswered ? (sidecarScoped ? "yes" : "NO -- it can reach it") : "unknown, it did not report")")

guard relayed, returned else {
    print("\nFAIL: the relay did not carry bytes end to end")
    exit(1)
}
guard sidecarAnswered, sidecarScoped else {
    print("\nFAIL: the relay is not scoped to the container that asked for it")
    exit(1)
}
print("\nPASS: \(hostSocket.lastPathComponent) on the Mac is \(destination) in the pod,")
print("      and only in the container that asked for it")
