// Pod networking, described by a CNI configuration instead of compiled in.
//
// The docs used to say "ferry has no CNI". It was never true that CNI needs
// Linux: CNI is a protocol -- JSON on stdin, JSON on stdout, the verb in the
// environment -- and whether a plugin needs a kernel is a property of that
// plugin, not of CNI.
//
// What ferry lacked was the runtime. ferry-cni is it, and this is the other end
// of the pipe: ferry-cri invokes it the way any runtime invokes a CNI chain,
// once before the VM boots and once after.
//
// Who chooses the address. Not this. vmnet does, because this node's vmnet
// network is its slice of the cluster CIDR and that is what puts the Mac on the
// pod network -- see docs/POD-NETWORK.md. So the host half of the chain is
// *told* the address rather than asked for one, through upstream's `static`
// IPAM and CNI's own `ips` capability. That is not a workaround: a runtime that
// already knows an address is exactly what `static` is for.
//
// Why the chain still runs in two halves. Virtualization.framework cannot
// hotplug a device, so the interface has to be described before the kernel
// starts -- and a plugin that wants to touch a netns cannot run until there is
// a kernel to hold one:
//
//	host    ferry-vm + static, forked on the Mac, before boot
//	guest   portmap and the rest, inside the pod, against its own root netns

import Foundation

struct CNIPortMapping: Encodable, Sendable {
    var hostPort: Int32
    var containerPort: Int32
    var `protocol`: String
    var hostIP: String?
}

/// Invokes ferry-cni. One process per call, as CNI intends.
struct CNIRuntime: Sendable {
    enum Stage: String, Sendable {
        case host, guest
    }

    /// The interface a chain produced, in the terms ferry-cri needs to build a VM.
    struct Attachment: Sendable {
        var address: String
        var gateway: String?
        var routes: [String]
    }

    let binary: String
    let conflist: String
    let hostPlugins: String
    let guestPlugins: String
    let cacheDir: String
    /// Where ferry-cri listens for exec requests. ferry-cni dials back here to
    /// run a guest plugin, because this process owns the virtual machines.
    let execSocket: String?

    /// The NIC a pod's address lands on. eth0 is vmnet and keeps the default
    /// route; eth1 is the cluster segment and is the address Kubernetes knows.
    static let interfaceName = "eth1"
    /// Where the guest plugin directory is mounted in every pod. CNI's own
    /// conventional location, because that is what it is.
    static let guestPluginPath = "/opt/cni/bin"
    /// CNI_NETNS inside a pod VM. A pod is one kernel, so its root netns is the
    /// sandbox -- there is no namespace to enter, and setns to the namespace a
    /// process is already in is a legal no-op.
    static let guestNetNS = "/proc/self/ns/net"

    @discardableResult
    func add(sandboxID: String, stage: Stage, execContainer: String? = nil,
             portMappings: [CNIPortMapping] = [], addresses: [String] = []) async throws -> Attachment? {
        let arguments = try invocation("add", sandboxID: sandboxID, stage: stage,
                                       execContainer: execContainer,
                                       portMappings: portMappings, addresses: addresses)
        let output = try await Self.run(binary, arguments)
        return Self.attachment(from: output)
    }

    func del(sandboxID: String, stage: Stage, execContainer: String? = nil,
             portMappings: [CNIPortMapping] = []) async throws {
        let arguments = try invocation("del", sandboxID: sandboxID, stage: stage,
                                       execContainer: execContainer, portMappings: portMappings)
        _ = try await Self.run(binary, arguments)
    }

    private func invocation(_ command: String, sandboxID: String, stage: Stage,
                            execContainer: String?, portMappings: [CNIPortMapping],
                            addresses: [String] = []) throws -> [String] {
        var arguments = [
            command,
            "--conflist", conflist,
            "--container-id", sandboxID,
            "--ifname", Self.interfaceName,
            "--netns", Self.guestNetNS,
            "--stage", stage.rawValue,
            "--cache-dir", cacheDir,
            "--host-plugins", hostPlugins,
            "--guest-plugins", guestPlugins,
            "--guest-plugin-path", Self.guestPluginPath,
        ]
        if stage == .guest {
            guard let execSocket, let execContainer else {
                throw RuntimeFailure.invalid("the guest half of a CNI chain needs a running container to exec in")
            }
            arguments.append(contentsOf: ["--exec-socket", execSocket, "--exec-container", execContainer])
        }
        // Both of these are CNI capabilities: values a runtime knows and the
        // configuration cannot. `ips` is how the address vmnet chose reaches
        // `static`, and `portMappings` is how a pod's hostPorts reach portmap.
        var capabilities: [String: Any] = [:]
        if !addresses.isEmpty { capabilities["ips"] = addresses }
        if !portMappings.isEmpty {
            capabilities["portMappings"] = portMappings.map { mapping -> [String: Any] in
                var entry: [String: Any] = [
                    "hostPort": mapping.hostPort,
                    "containerPort": mapping.containerPort,
                    "protocol": mapping.protocol,
                ]
                if let hostIP = mapping.hostIP { entry["hostIP"] = hostIP }
                return entry
            }
        }
        if !capabilities.isEmpty {
            let encoded = try JSONSerialization.data(withJSONObject: capabilities, options: [.sortedKeys])
            arguments.append(contentsOf: ["--capability-args", String(decoding: encoded, as: UTF8.self)])
        }
        return arguments
    }

    /// Reads the address, gateway and routes out of a CNI result.
    private static func attachment(from output: Data) -> Attachment? {
        guard let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              let ips = object["ips"] as? [[String: Any]],
              let first = ips.first,
              let address = first["address"] as? String
        else { return nil }
        var routes: [String] = []
        for route in object["routes"] as? [[String: Any]] ?? [] {
            if let destination = route["dst"] as? String { routes.append(destination) }
        }
        return Attachment(address: address, gateway: first["gateway"] as? String, routes: routes)
    }

    /// Runs ferry-cni and returns what it printed.
    ///
    /// Asynchronously, and that is load-bearing rather than tidiness: the guest
    /// half of a chain calls back into this process's exec socket, so a
    /// blocking wait here would deadlock against the reply. Suspending at an
    /// await leaves the actor free to serve it.
    private static func run(_ executable: String, _ arguments: [String]) async throws -> Data {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let collected = Collector()
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { collected.appendOut(chunk) }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { collected.appendErr(chunk) }
        }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        // The handlers run on a private queue; give whatever is still buffered a
        // chance to land before the pipes are dropped.
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        collected.appendOut((try? out.fileHandleForReading.readToEnd()) ?? Data())
        collected.appendErr((try? err.fileHandleForReading.readToEnd()) ?? Data())

        let stderr = collected.errBytes
        if !stderr.isEmpty {
            FileHandle.standardError.write(stderr)
        }
        guard status == 0 else {
            throw RuntimeFailure.invalid(
                "ferry-cni \(arguments.first ?? "") exited \(status): "
                + String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return collected.outBytes
    }

    /// Accumulates a subprocess's output from the queue its handlers run on.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()
        func appendOut(_ data: Data) { lock.lock(); out.append(data); lock.unlock() }
        func appendErr(_ data: Data) { lock.lock(); err.append(data); lock.unlock() }
        var outBytes: Data { lock.lock(); defer { lock.unlock() }; return out }
        var errBytes: Data { lock.lock(); defer { lock.unlock() }; return err }
    }
}

extension CNIRuntime {
    /// Writes the configuration ferry runs when none was supplied.
    ///
    /// There is no `dataDir`, no range and no node arithmetic in it, because
    /// ferry is not choosing addresses -- vmnet already did, and the runtime
    /// hands that address to `static` per pod. What is left in the file is the
    /// shape of the chain, which is the part worth being able to read and edit.
    static func writeDefaultConflist(at path: String, clusterCIDR: String?) throws {
        var plugins: [[String: Any]] = [
                [
                    "type": "ferry-vm",
                    // The address arrives as a runtime capability, because it is
                    // per pod and nothing in a file could know it. It is
                    // declared here rather than in the ipam section because a
                    // capability belongs to the plugin the runtime invokes, and
                    // the delegate reads the same configuration this one gets.
                    "capabilities": ["ips": true],
                    "ipam": ["type": "static"],
                ],
                [
                    "type": "portmap",
                    // ferry ships nft into every pod and its kernel can NAT, so
                    // the nftables backend is the one that works here.
                    "backend": "nftables",
                    // SNAT exists to let a connection from 127/8 cross a
                    // routing boundary, and turning it on makes portmap write
                    // route_localnet -- into a /proc/sys the pod mounts
                    // read-only. Nothing here needs it: a hostPort connection
                    // arrives from the Mac with a real source address, never
                    // from loopback.
                    "snat": false,
                    "capabilities": ["portMappings": true],
                ],
        ]

        // SCTP takes the switch rather than vmnet, which does not carry it.
        // Only meaningful once there is a cluster network to have a switch on,
        // so a vmnet-only cluster does not get the plugin at all.
        //
        // The network to redirect is deliberately not written here. ferry asks
        // vmnet for a subnet matching the cluster slice and does not always get
        // it; when it does not, the pods are somewhere else entirely and a CIDR
        // recorded at this point would name a network none of them are on. The
        // plugin reads it from the switch interface instead, which is by
        // definition right.
        if let clusterCIDR, !clusterCIDR.isEmpty {
            plugins.append([
                "type": "ferry-sctp",
                "device": "eth1",
            ])
        }

        let conflist: [String: Any] = [
            "cniVersion": "1.0.0",
            "name": "ferry",
            "plugins": plugins,
        ]
        let encoded = try JSONSerialization.data(withJSONObject: conflist,
                                                 options: [.prettyPrinted, .sortedKeys])
        try encoded.write(to: URL(filePath: path))
    }
}
