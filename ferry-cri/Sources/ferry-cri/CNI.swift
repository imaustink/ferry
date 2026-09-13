// Pod networking, described by a CNI configuration instead of compiled in.
//
// ferry used to pick pod addresses itself, in Swift, and the docs called that
// "ferry has no CNI". It was never true that CNI needs Linux: CNI is a protocol
// -- JSON on stdin, JSON on stdout, the verb in the environment -- and whether
// a plugin needs a kernel is a property of that plugin. Upstream's IPAM plugins
// build native Mach-O.
//
// What ferry lacked was the runtime. ferry-cni is it, and this is the other end
// of the pipe: ferry-cri invokes it the way any runtime invokes a CNI chain,
// once before the VM boots and once after.
//
// Why twice. Virtualization.framework cannot hotplug a device, so a pod's
// address has to be chosen before the kernel starts -- and a plugin that wants
// to touch a netns cannot run until there is a kernel to hold one. That is the
// same line the plugin set already splits along, so the split is not a
// compromise, it is the shape of the problem:
//
//	host    ferry-vm + host-local, forked on the Mac, before boot
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
             portMappings: [CNIPortMapping] = [], requestedIP: String? = nil) async throws -> Attachment? {
        var arguments = try invocation("add", sandboxID: sandboxID, stage: stage,
                                       execContainer: execContainer, portMappings: portMappings)
        if let requestedIP {
            // host-local honours an explicit address through CNI_ARGS, which is
            // how the cluster DNS address stays the one the kubelet was told.
            arguments.append(contentsOf: ["--args", "IP=\(requestedIP)"])
        }
        let output = try await Self.run(binary, arguments)
        return Self.attachment(from: output)
    }

    /// Releases every lease except the ones named.
    ///
    /// ferry-cri's pods do not survive it: the VMs stop when the process that
    /// owns them does. Their leases are files and do survive, so on startup the
    /// only attachments that are still real are the ones this process is about
    /// to make -- and the cluster DNS address it holds itself.
    func gc(keep: [String]) async throws {
        var arguments = [
            "gc",
            "--conflist", conflist,
            "--ifname", Self.interfaceName,
            "--cache-dir", cacheDir,
            "--host-plugins", hostPlugins,
            "--guest-plugins", guestPlugins,
        ]
        if !keep.isEmpty {
            arguments.append(contentsOf: ["--keep", keep.joined(separator: ",")])
        }
        _ = try await Self.run(binary, arguments)
    }

    func del(sandboxID: String, stage: Stage, execContainer: String? = nil,
             portMappings: [CNIPortMapping] = []) async throws {
        let arguments = try invocation("del", sandboxID: sandboxID, stage: stage,
                                       execContainer: execContainer, portMappings: portMappings)
        _ = try await Self.run(binary, arguments)
    }

    private func invocation(_ command: String, sandboxID: String, stage: Stage,
                            execContainer: String?, portMappings: [CNIPortMapping]) throws -> [String] {
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
        if !portMappings.isEmpty {
            let encoded = try JSONEncoder().encode(["portMappings": portMappings])
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
    /// Everything here used to be Swift: this node's slice of the cluster, the
    /// first usable address, the mask that makes the whole cluster on-link. Now
    /// it is a file, which is the point -- rangeStart, several ranges and IPv6
    /// come from editing it rather than from changing ferry.
    ///
    /// The subnet is the whole cluster and the range is only this node's /24.
    /// That is not a flourish: a pod's NIC gets the subnet's mask and there is
    /// no router on the segment, so a /24 would leave every other node's pods
    /// unreachable. One flat segment, one slice of it per node, is exactly what
    /// ferry already did -- said out loud for the first time.
    static func writeDefaultConflist(at path: String, clusterCIDR: String,
                                     nodeIndex: Int, leasesDir: String) throws {
        let parts = clusterCIDR.split(separator: "/")
        let octets = parts.first?.split(separator: ".") ?? []
        guard parts.count == 2, octets.count == 4, nodeIndex >= 0, nodeIndex <= 255
        else { throw RuntimeFailure.invalid("cluster CIDR \(clusterCIDR) is not an IPv4 network") }
        let prefix = "\(octets[0]).\(octets[1]).\(nodeIndex)"

        let conflist: [String: Any] = [
            "cniVersion": "1.0.0",
            "name": "ferry",
            "plugins": [
                [
                    "type": "ferry-vm",
                    "ipam": [
                        "type": "host-local",
                        "dataDir": leasesDir,
                        // .1 is left out so it reads as a gateway even though
                        // there is none, and .2 is the cluster DNS address,
                        // reserved at startup before any pod can ask.
                        "ranges": [[["subnet": clusterCIDR,
                                     "rangeStart": "\(prefix).2",
                                     "rangeEnd": "\(prefix).254"]]],
                    ],
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
                    // arrives from the Mac over vmnet with a real source
                    // address, never from loopback.
                    "snat": false,
                    "capabilities": ["portMappings": true],
                ],
            ],
        ]
        let encoded = try JSONSerialization.data(withJSONObject: conflist,
                                                 options: [.prettyPrinted, .sortedKeys])
        try encoded.write(to: URL(filePath: path))
    }

    /// The address cluster DNS is pinned to, and the name its lease is held
    /// under. It is an ordinary host-local lease, so unlike the reservation it
    /// replaces it survives a restart.
    static func dnsAddress(clusterCIDR: String, nodeIndex: Int) -> String? {
        let octets = clusterCIDR.split(separator: "/").first?.split(separator: ".") ?? []
        guard octets.count == 4 else { return nil }
        return "\(octets[0]).\(octets[1]).\(nodeIndex).2"
    }

    static let dnsLeaseID = "ferry-cluster-dns"
}
