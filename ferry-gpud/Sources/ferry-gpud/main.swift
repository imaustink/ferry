// ferry-gpud: the Mac's GPU, offered to pods over a socket.
//
// There is no GPU pass-through on Apple silicon -- Virtualization.framework
// has no PCI passthrough and no compute device, and the GPU is reachable only
// through Metal, in a macOS process. So the work does not move into the pod;
// the pod reaches out to a process that is already on the right side of the
// boundary. See docs/GPU.md.

import Foundation

setvbuf(stdout, nil, _IONBF, 0)

let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String, _ fallback: String) -> String {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return fallback }
    return args[i + 1]
}

let controlSocket = option("--control", "/tmp/ferry-run/gpud.sock")
// Pod sockets live here and are named by pod uid. Kept short deliberately:
// macOS caps a unix socket path near 104 bytes and a uid spends 36 of them.
let socketDirectory = option("--socket-dir", "/tmp/ferry-run/gpu")
let limit = Int(option("--capacity", "1")) ?? 1

let gpu: GPU
do {
    gpu = try GPU()
} catch {
    FileHandle.standardError.write(Data("ferry-gpud: \(error)\n".utf8))
    exit(1)
}

// Created now rather than on the first grant, and 0700: the sockets that will
// appear here are the GPU, and on a shared Mac they should not be openable by
// every local account. A directory the starter made 0755 would leave a window.
do {
    try FileManager.default.createDirectory(
        atPath: socketDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    chmod(socketDirectory, 0o700)
} catch {
    FileHandle.standardError.write(Data("ferry-gpud: \(socketDirectory): \(error)\n".utf8))
    exit(1)
}

let service = Service(gpu: gpu, socketDirectory: socketDirectory, limit: limit)

print("==> ferry-gpud")
print("    device    \(gpu.info.name) (\(gpu.info.architecture))")
print("    memory    \(gpu.info.recommendedWorkingSetMiB) MiB recommended working set")
let model = Generator().status
print("    model     \(model.available ? "on-device model available" : (model.reason ?? "unavailable"))")
print("    capacity  \(limit) pod\(limit == 1 ? "" : "s")")
print("    control   unix://\(controlSocket)")
print("    pods      \(socketDirectory)/<uid>.sock")

let control = UnixHTTPServer(path: controlSocket) { request, identity in
    service.handleControl(request, identity: identity)
}
do {
    try control.start()
} catch {
    FileHandle.standardError.write(Data("ferry-gpud: \(error)\n".utf8))
    exit(1)
}

// Sockets are filesystem objects; leaving them behind makes the next start look
// like something is already listening when nothing is.
//
// Through a dispatch source rather than a signal(2) handler: the cleanup takes
// locks and logs, and neither is async-signal-safe. The default disposition has
// to be ignored first, or the process dies before the source ever runs.
let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        log("stopping")
        service.revokeAll()
        control.stop()
        exit(0)
    }
    source.resume()
    return source
}

log("ready")
dispatchMain()
