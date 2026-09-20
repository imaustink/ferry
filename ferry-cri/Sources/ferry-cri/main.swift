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
    defaultMemoryBytes: (UInt64(option("--pod-memory-mib", "512")) ?? 512) * 1024 * 1024,
    nftBundlePath: {
        let path = option("--nft-bundle", "")
        return path.isEmpty ? nil : path
    }(),
    proxydSocket: {
        let path = option("--proxyd-socket", "")
        return path.isEmpty ? nil : path
    }(),
    netpolSocket: {
        let path = option("--netpol-socket", "")
        return path.isEmpty ? nil : path
    }(),
    gpudSocket: {
        let path = option("--gpud-socket", "")
        return path.isEmpty ? nil : path
    }(),
    clusterCIDR: {
        let cidr = option("--cluster-cidr", "")
        return cidr.isEmpty ? nil : cidr
    }(),
    nodeIndex: Int(option("--node-index", "0")) ?? 0,
    relayPort: UInt16(option("--relay-port", "0")) ?? 0,
    peers: {
        let list = option("--peers", "")
        return list.isEmpty ? [] : list.split(separator: ",").map(String.init)
    }(),
    peersFile: {
        let path = option("--peers-file", "")
        return path.isEmpty ? nil : path
    }(),
    relayEndpoint: {
        let endpoint = option("--relay-endpoint", "")
        return endpoint.isEmpty ? nil : endpoint
    }(),
    machineSwitch: {
        let endpoint = option("--machine-switch", "")
        return endpoint.isEmpty ? nil : endpoint
    }(),
    cniBinary: {
        let path = option("--cni", "")
        return path.isEmpty ? nil : path
    }(),
    cniConflist: {
        let path = option("--cni-conflist", "")
        return path.isEmpty ? nil : path
    }(),
    cniHostPlugins: {
        let path = option("--cni-host-plugins", "")
        return path.isEmpty ? nil : path
    }(),
    cniGuestPlugins: {
        let path = option("--cni-guest-plugins", "")
        return path.isEmpty ? nil : path
    }(),
    execSocket: execSocketPath
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
//
// The handler is built by `onShutdownSignal` rather than written here, and that
// is not tidiness: a closure written in top-level code inherits `@MainActor`,
// dispatch calls signal handlers off the main queue, and Swift traps on the
// isolation check. This handler used to crash on every SIGTERM without ever
// reaching its first line. See Shutdown.swift.
//
// beginGracefulShutdown is part of that, and not decoration: the kubelet is
// very likely mid-RPC when `ferry down` arrives, and without it those calls are
// cut by exit(0) and the kubelet sees a connection reset where it should have
// seen an answer.
let shutdownSocketPath = socketPath
let shutdownSignals = onShutdownSignal {
    Task.detached {
        announce("\n==> stopping pods and releasing the pod network")
        await runtime.shutdown()
        server.beginGracefulShutdown()
        try? FileManager.default.removeItem(atPath: shutdownSocketPath)
        announce("==> stopped")
        exit(0)
    }
}
_ = shutdownSignals

if config.nftBundlePath != nil, let proxyd = config.proxydSocket {
    print("    services  kube-proxy rules applied in-guest (from \(proxyd))")
    // Poll rather than subscribe: the ruleset is small, changes are rare, and
    // this keeps ferry-cri free of an API client of its own.
    // Service rules follow the cluster rather than a clock: each pass asks
    // ferry-proxyd for something newer than it last saw, and ferry-proxyd holds
    // the request until a Service actually changes. The only sleeping is a
    // backoff for when ferry-proxyd is not up yet.
    //
    // The fetch runs on a thread of its own rather than on the runtime actor.
    // It blocks for as long as the cluster is quiet, and the actor has pods to
    // start and stop in the meantime.
    // NetworkPolicy, one pod at a time. Same bargain as the Service ruleset: ask
    // for something newer than what we have and be held until there is some.
    if let netpol = runtime.netpolClient {
        Task {
            while true {
                let seen = await runtime.seenPolicyGeneration()
                guard let next = try? await fetchRuleset(netpol, after: seen, path: "/rules") else {
                    try? await Task.sleep(for: .seconds(3))
                    continue
                }
                await runtime.applyPolicies(
                    String(data: next.body, encoding: .utf8) ?? "", generation: next.generation)
            }
        }
    }

    if let proxyd = runtime.proxydClient {
        Task {
            if let first = try? await fetchRuleset(proxyd, after: nil) {
                await runtime.cacheRuleset(first.body, generation: first.generation)
            }
            while true {
                let seen = await runtime.seenGeneration()
                guard let next = try? await fetchRuleset(proxyd, after: seen) else {
                    try? await Task.sleep(for: .seconds(3))
                    continue
                }
                await runtime.applyRuleset(next.body, generation: next.generation)
            }
        }
    }
}

/// Fetches a ruleset off the calling actor, because the read blocks until
/// ferry-proxyd has something to say.
func fetchRuleset(_ proxyd: StreamerClient, after generation: UInt64?,
                  path: String = "/ruleset") async throws -> StreamerClient.Ruleset {
    try await Task.detached(priority: .utility) {
        try proxyd.ruleset(after: generation, path: path)
    }.value
}

print("    serving")
try await server.serve()
