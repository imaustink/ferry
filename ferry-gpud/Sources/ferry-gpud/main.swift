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
let limit = max(1, Int(option("--capacity", "1")) ?? 1)
// Every request gets a deadline, queue time included. Without one, a pod can
// hold the only GPU for as long as it likes and every other pod waits.
let requestTimeout = TimeInterval(option("--request-timeout", "120")) ?? 120
// How many requests may be waiting for the device before new ones are refused,
// and how many any one pod may have among them.
let queueDepth = max(1, Int(option("--queue-depth", "64")) ?? 64)
let perPodDepth = max(1, Int(option("--pod-queue-depth", "8")) ?? 8)
// The largest share of the GPU's recommended working set one request may
// allocate.
let memoryFraction = min(max(Double(option("--memory-fraction", "0.25")) ?? 0.25, 0.01), 1.0)
// How long to let in-flight work finish on the way down.
let drainTimeout = TimeInterval(option("--drain-timeout", "10")) ?? 10

let gpu: GPU
do {
    gpu = try GPU(memoryFraction: memoryFraction)
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

let scheduler = GPUScheduler(queueDepth: queueDepth, perPodDepth: perPodDepth)
let service = Service(gpu: gpu, scheduler: scheduler, socketDirectory: socketDirectory,
                      limit: limit, requestTimeout: requestTimeout)

print("==> ferry-gpud")
print("    device    \(gpu.info.name) (\(gpu.info.architecture))")
print("    memory    \(gpu.info.recommendedWorkingSetMiB) MiB working set, "
      + "\(gpu.memoryCeilingMiB) MiB per request")
let model = Generator().status
print("    model     \(model.available ? "on-device model available" : (model.reason ?? "unavailable"))")
print("    capacity  \(limit) pod\(limit == 1 ? "" : "s"), "
      + "\(Int(requestTimeout))s per request, \(queueDepth) queued (\(perPodDepth) per pod)")
print("    control   unix://\(controlSocket)")
print("    pods      \(socketDirectory)/<uid>.sock")

// Anything a previous instance had granted. A pod whose socket reappears at the
// same path works again, because the relay dials on demand.
service.restore()

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
        log("stopping; draining for up to \(Int(drainTimeout))s")
        service.drain(timeout: drainTimeout)
        control.stop()
        log("stopped")
        exit(0)
    }
    source.resume()
    return source
}

log("ready")
dispatchMain()
