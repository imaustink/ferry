// ferry-cri: a CRI runtime that gives every pod its own virtual machine.

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

// Unbuffered: this process can be killed by the VM subsystem, and a buffered
// stdout would discard exactly the log that says how far it got.
setvbuf(stdout, nil, _IONBF, 0)

let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String, _ fallback: String) -> String {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return fallback }
    return args[i + 1]
}

let socketPath = option("--endpoint", "/tmp/ferry-cri.sock")
let execSocketPath = option("--exec-socket", "/tmp/ferry-exec.sock")
let streamerControl = option("--streamer-control", "/tmp/ferry-streamer.sock")
let config = RuntimeConfig(
    stateDir: URL(filePath: option("--state", "/tmp/ferry-cri")),
    kernelPath: option("--kernel", "experiments/03-vm-ceiling/assets/vmlinux-arm64"),
    podSubnet: option("--pod-subnet", "192.168.66.1/24"),
    initImage: option("--init-image", "ghcr.io/apple/containerization/vminit:0.45.0"),
    defaultCPUs: Int(option("--pod-cpus", "2")) ?? 2,
    defaultMemoryBytes: (UInt64(option("--pod-memory-mib", "512")) ?? 512) * 1024 * 1024
)

guard FileManager.default.fileExists(atPath: config.kernelPath) else {
    FileHandle.standardError.write(
        "no kernel at \(config.kernelPath); run experiments/03-vm-ceiling/fetch-kernel.sh\n".data(using: .utf8)!)
    exit(1)
}

print("==> ferry-cri")
print("    endpoint  unix://\(socketPath)")
print("    state     \(config.stateDir.path())")
print("    kernel    \(config.kernelPath)")
print("    pod size  \(config.defaultCPUs) cpu, \(config.defaultMemoryBytes / 1024 / 1024) MiB")

let runtime = try PodRuntime(config: config)
await runtime.setStreamer(StreamerClient(socketPath: streamerControl))
do {
    try await runtime.prepare()
} catch {
    FileHandle.standardError.write("failed to prepare runtime: \(error)\n".data(using: .utf8)!)
    exit(1)
}
print("    network   \(await runtime.subnet), gateway \(await runtime.gateway)")

// kubectl exec arrives over SPDY, which ferry-streamer terminates; it reaches
// pods through this socket.
let execServer = ExecServer(path: execSocketPath, runtime: runtime)
do {
    try execServer.start()
    print("    exec      unix://\(execSocketPath)")
} catch {
    print("    exec      unavailable: \(error)")
}

try? FileManager.default.removeItem(atPath: socketPath)
let server = GRPCServer(
    transport: .http2NIOPosix(
        address: .unixDomainSocket(path: socketPath),
        transportSecurity: .plaintext
    ),
    services: [
        FerryRuntimeService(runtime: runtime, version: "0.1.0",
                            streamer: StreamerClient(socketPath: streamerControl)),
        FerryImageService(runtime: runtime),
    ]
)

// Shut down cleanly on signal. A ferry-cri that is simply killed leaves its
// pods running and its vmnet network claimed, and the next process to ask for
// the same subnet is refused.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let shutdownSignals = [SIGTERM, SIGINT].map { sig -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    source.setEventHandler {
        Task {
            print("\n==> stopping pods and releasing the pod network")
            await runtime.shutdown()
            server.beginGracefulShutdown()
            try? FileManager.default.removeItem(atPath: socketPath)
            exit(0)
        }
    }
    source.resume()
    return source
}
_ = shutdownSignals

print("    serving")
try await server.serve()
