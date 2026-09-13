// The runtime behind the CRI surface: one virtual machine per pod.
//
// A CRI sandbox becomes a LinuxPod, and a CRI container becomes a process with
// its own root filesystem inside that pod's VM. Containers in a pod therefore
// share a network stack and an IPC namespace because they share a kernel --
// there is no pause container and no namespace plumbing, the VM boundary is the
// pod boundary.

import Containerization
import ContainerizationEXT4
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Synchronization

struct RuntimeConfig: Sendable {
    var stateDir: URL
    var kernelPath: String
    var podSubnet: String
    var initImage: String
    var defaultCPUs: Int
    var defaultMemoryBytes: UInt64
    /// Host directory holding nft and its loader, mounted into every pod so it
    /// can apply the Service rules kube-proxy rendered.
    var nftBundlePath: String?
    /// ferry-proxyd's socket, where the rendered ruleset comes from.
    var proxydSocket: String?
    /// ferry-netpol's socket, where each pod's NetworkPolicy rules come from.
    var netpolSocket: String?
    /// The cluster pod network, one flat segment across every node on every
    /// machine. Empty leaves ferry on vmnet addressing and a single node.
    var clusterCIDR: String?
    /// This node's slice of it. Pods here are 10.244.<index>.x when the cluster
    /// network is 10.244.0.0/16.
    var nodeIndex: Int
    /// UDP port carrying frames to other machines. 0 keeps the switch local.
    var relayPort: UInt16
    /// host:port of the other nodes' switches, at startup.
    var peers: [String]
    /// A file listing every relay endpoint in the cluster, kept current by
    /// ferry-streamer as nodes join and leave.
    var peersFile: String?
    /// This node's own endpoint, so it can be skipped in that list.
    var relayEndpoint: String?
}

enum RuntimeFailure: Error, CustomStringConvertible {
    case notFound(String)
    case invalid(String)
    case unsupported(String)

    var description: String {
        switch self {
        case .notFound(let m): "not found: \(m)"
        case .invalid(let m): "invalid: \(m)"
        case .unsupported(let m): "unsupported: \(m)"
        }
    }
}

struct SandboxRecord {
    let id: String
    var pod: LinuxPod
    let name: String
    let uid: String
    let namespace: String
    let attempt: UInt32
    let labels: [String: String]
    let annotations: [String: String]
    let ip: String
    let logDirectory: String
    let createdAt: Int64
    var ready: Bool = true
    /// Whether the VM has been booted. Virtualization.framework cannot hotplug,
    /// so containers must all be added before `create()`; the VM is therefore
    /// booted lazily on the first StartContainer rather than at RunPodSandbox.
    var booted: Bool = false
    var usesReservedAddress: Bool = false
    /// The pod's address on the cluster network, to hand back when it stops.
    var clusterAddress: String? = nil
    /// The pod's vmnet address. `ip` is what Kubernetes calls the pod IP and
    /// lives on the cluster network, which only pods are on -- so anything the
    /// Mac itself does, port-forward and the host side of a Service, needs this
    /// one instead.
    var hostAddress: String = ""
    /// Kept so the VM can be rebuilt if every container in it has stopped --
    /// see createContainer.
    let interface: any Interface
    let config: Runtime_V1_PodSandboxConfig
    /// Names of the pod's regular containers, from its spec. The kubelet
    /// creates them one at a time and this hypervisor cannot add a container to
    /// a running VM, so the boot waits until they have all arrived. Empty when
    /// the pod spec could not be read, in which case the VM boots on the first
    /// start as it always did.
    var expectedContainers: [String] = []
    var initContainerNames: [String] = []
    /// Containers the kubelet has started that are waiting for the VM.
    var pendingStart: [String] = []
}

struct ContainerRecord {
    let id: String
    let sandboxID: String
    let name: String
    let attempt: UInt32
    let image: String
    let imageRef: String
    let labels: [String: String]
    let annotations: [String: String]
    let logPath: String
    let createdAt: Int64
    var startedAt: Int64 = 0
    var finishedAt: Int64 = 0
    var exitCode: Int32 = 0
    var state: ContainerRunState = .created
    var reason: String = ""
    var tty: Bool = false
    var logWriters: [ContainerLogWriter] = []
    var logFile: ContainerLogFile?
    /// Present only when the pod spec set stdin. A container that did not ask
    /// for stdin must see it closed, or anything reading from it hangs instead
    /// of getting EOF.
    var stdinFeeder: FrameReaderStream?
}

enum ContainerRunState {
    case created, running, exited
}

actor PodRuntime {
    private let config: RuntimeConfig
    private let store: ImageStore
    private let kernel: Kernel
    private var initfs: Containerization.Mount!
    private var network: VmnetNetwork!

    /// An address held back for cluster DNS. CoreDNS has to live at an address
    /// the kubelet can be configured with before CoreDNS exists, so one is
    /// reserved at startup and handed to whichever sandbox asks for it by
    /// annotation. Without this the kubelet's clusterDNS would have to be
    /// guessed, or changed after the fact and the kubelet restarted.
    private var dnsInterface: (any Interface)?
    private var dnsInterfaceInUse = false

    /// Annotation a pod sets to claim the reserved DNS address.
    static let reservedAddressAnnotation = "ferry.sh/reserved-address"

    private var sandboxes: [String: SandboxRecord] = [:]
    private var containers: [String: ContainerRecord] = [:]

    /// Unpacked, read-only root filesystems keyed by image reference. Each
    /// container gets a writable clone of one of these rather than unpacking
    /// the image again.
    private var rootfsCache: [String: Containerization.Mount] = [:]
    private var pulledImages: [String: Runtime_V1_Image] = [:]
    /// The image's own entrypoint, cmd, env and working directory. The kubelet
    /// sends only the pod's overrides, so without this a container built around
    /// an ENTRYPOINT gets its arguments alone and fails to exec.
    private var imageConfigs: [String: ContainerizationOCI.ImageConfig] = [:]

    private var idCounter: UInt64 = 0
    /// Used only to read pod specs, so the VM can wait for a pod's whole
    /// container set before booting.
    var streamer: StreamerClient?

    init(config: RuntimeConfig) throws {
        self.config = config
        try FileManager.default.createDirectory(at: config.stateDir, withIntermediateDirectories: true)
        self.store = try ImageStore(path: config.stateDir)
        self.kernel = Kernel(path: URL(filePath: config.kernelPath), platform: .linuxArm)
    }

    /// Pulls the guest agent image and creates the pod network. Kept out of
    /// init so failures surface with context before the server starts serving.
    func setStreamer(_ client: StreamerClient) { self.streamer = client }

    func prepare() async throws {
        let initImage = try await store.getInitImage(reference: config.initImage)
        let initPath = config.stateDir.appending(component: "init.ext4")
        do {
            self.initfs = try await initImage.initBlock(at: initPath, for: .linuxArm)
        } catch let error as ContainerizationError where error.code == .exists {
            self.initfs = .block(format: "ext4", source: initPath.path(), destination: "/", options: ["ro"])
        }
        // A vmnet subnet stays reserved for about a minute after the process
        // using it exits -- measured, not guessed: see experiments/07-vmnet-leak.
        // So a restart normally cannot have its previous subnet back, and waiting
        // for it would cost the user a minute of startup for nothing. Moving to
        // another is right; what it costs is a changed gateway, which is part of
        // the CoreDNS manifest and so rolls CoreDNS out again.
        var chosen: VmnetNetwork?
        var lastError: Error?
        for candidate in Self.subnetCandidates(preferred: config.podSubnet) {
            do {
                chosen = try VmnetNetwork(subnet: try CIDRv4(candidate))
                if candidate != config.podSubnet {
                    print("    \(config.podSubnet) is still reserved by a recent run; using \(candidate)")
                }
                lastError = nil
                break
            } catch {
                lastError = error
            }
        }
        guard let chosen else {
            // vmnet allows 32 networks across the whole Mac, shared with anything
            // else using it, and each of ferry's is held for about a minute after
            // it stops. Enough restarts in quick succession exhausts the list, and
            // the raw VMNET_FAILURE says none of that.
            throw lastError ?? RuntimeFailure.unsupported(
                "no pod subnet is available. vmnet allows 32 networks across the "
                + "whole Mac and holds each for about a minute after the process "
                + "using it stops, so this usually clears on its own -- wait a "
                + "minute and try again. Otherwise check for other VMs still running.")
        }
        self.network = chosen

        // The API server has to advertise the gateway of whichever subnet was
        // actually obtained, so publish it for whoever starts the control plane.
        try? "\(chosen.ipv4Gateway)\n".write(
            to: config.stateDir.appending(component: "gateway"),
            atomically: true, encoding: .utf8)

        // The cluster pod network, if this is a cluster rather than one node.
        // eth0 stays on vmnet for the internet and the host; this is eth1, and
        // it is the address Kubernetes knows a pod by.
        if let cidr = config.clusterCIDR,
           var addresses = RotatingAddresses(clusterCIDR: cidr, nodeIndex: config.nodeIndex) {
            self.podSwitch = PodSwitch(relayPort: config.relayPort, peers: config.peers,
                                       peersFile: config.peersFile,
                                       self: config.relayEndpoint)
            if let reserved = addresses.takeReserved() {
                let bare = reserved.split(separator: "/").first.map(String.init) ?? ""
                try? "\(bare)\n".write(to: config.stateDir.appending(component: "dns"),
                                        atomically: true, encoding: .utf8)
                self.clusterDNSAddress = reserved
            }
            self.clusterAddresses = addresses
            print("    pod network \(cidr), this node is \(addresses.prefix).0/24")
            if config.relayPort > 0 {
                print("    switch    udp/\(config.relayPort), peers: \(config.peers.isEmpty ? "none yet" : config.peers.joined(separator: ", "))")
            }
            return
        }

        // Reserve and publish the cluster DNS address before any pod can take it.
        if let reserved = try? self.network.createInterface("ferry-dns") {
            self.dnsInterface = reserved
            let address = "\(reserved.ipv4Address)".split(separator: "/").first.map(String.init) ?? ""
            try? "\(address)\n".write(
                to: config.stateDir.appending(component: "dns"),
                atomically: true, encoding: .utf8)
        }
    }

    var gateway: String { "\(network.ipv4Gateway)" }
    var subnet: String { "\(network.subnet)" }

    /// The preferred subnet first, then alternatives for when a recent run
    /// still holds it.
    private static func subnetCandidates(preferred: String) -> [String] {
        var candidates = [preferred]
        for third in [66, 77, 88, 99, 111, 122, 133, 144, 155, 166, 177, 188, 199, 211, 222] {
            let candidate = "192.168.\(third).1/24"
            if candidate != preferred { candidates.append(candidate) }
        }
        return candidates
    }

    private func nextID(_ prefix: String) -> String {
        idCounter += 1
        return String(format: "%@%015llx", prefix, idCounter)
    }

    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000_000_000) }

    // MARK: - Sandboxes

    func runPodSandbox(config cfg: Runtime_V1_PodSandboxConfig) async throws -> String {
        let id = nextID("sandbox")

        // A pod may claim the reserved DNS address by annotation, so cluster
        // DNS lands where the kubelet was already told to look.
        let wantsReserved = cfg.annotations[Self.reservedAddressAnnotation] == "dns"
        let interface: any Interface
        if wantsReserved, let reserved = dnsInterface, !dnsInterfaceInUse {
            interface = reserved
            dnsInterfaceInUse = true
        } else {
            guard let fresh = try network.createInterface(id) else {
                throw RuntimeFailure.invalid("pod network exhausted; no address available")
            }
            interface = fresh
        }
        var ip = "\(interface.ipv4Address)".split(separator: "/").first.map(String.init) ?? ""

        // eth1: the cluster network. Its address is what Kubernetes calls the
        // pod IP, because it is the one every other pod can reach -- on this
        // machine or another. eth0 keeps the default route and the internet.
        var clusterInterface: SwitchInterface?
        if podSwitch != nil, clusterAddresses != nil {
            let address: String?
            if wantsReserved, let reserved = clusterDNSAddress, !clusterDNSInUse {
                address = reserved
                clusterDNSInUse = true
            } else {
                address = clusterAddresses!.take()
            }
            guard let address, let cidr = try? CIDRv4(address) else {
                throw RuntimeFailure.invalid("the pod network has no addresses left")
            }
            let nic = try SwitchInterface(address: cidr, mac: nil)
            clusterInterface = nic
            ip = address.split(separator: "/").first.map(String.init) ?? ip
        }

        // Kubernetes sends resource limits per container, not per sandbox, so
        // the VM is sized from defaults here and containers are bounded inside
        // it by cgroups. Right-sizing the VM from the pod's aggregate requests
        // is a worthwhile refinement, not a correctness issue.
        let pod = try makePod(id: id, interface: interface, cfg: cfg,
                              clusterInterface: clusterInterface)
        if let clusterInterface {
            podSwitch?.attach(podID: id, fd: clusterInterface.hostFD)
        }
        defer { publishHostReachableMap() }
        // Deliberately not created yet. CRI adds containers after the sandbox
        // exists, and on this hypervisor a container can only be added before
        // the VM boots -- see startContainer.
        let expected = await podContainers(
            namespace: cfg.metadata.namespace, name: cfg.metadata.name)

        sandboxes[id] = SandboxRecord(
            id: id, pod: pod,
            name: cfg.metadata.name, uid: cfg.metadata.uid,
            namespace: cfg.metadata.namespace, attempt: cfg.metadata.attempt,
            labels: cfg.labels, annotations: cfg.annotations,
            ip: ip, logDirectory: cfg.logDirectory, createdAt: Self.now(),
            usesReservedAddress: wantsReserved && (dnsInterfaceInUse || clusterDNSInUse),
            clusterAddress: clusterInterface.map { "\($0.ipv4Address)" },
            hostAddress: "\(interface.ipv4Address)".split(separator: "/").first.map(String.init) ?? "",
            interface: interface, config: cfg,
            expectedContainers: expected.containers,
            initContainerNames: expected.initContainers
        )
        return id
    }

    /// Translates a CRI security context into the framework's capability sets.
    /// Kubernetes speaks in terms of adding to and dropping from a default set,
    /// and "ALL" is legal on either side.
    private static func capabilities(for security: Runtime_V1_LinuxContainerSecurityContext) -> Containerization.LinuxCapabilities {
        if security.privileged { return .allCapabilities }

        var names = Set(Containerization.LinuxCapabilities.defaultOCICapabilities.bounding)
        let drops = security.capabilities.dropCapabilities
        if drops.contains(where: { $0.uppercased() == "ALL" }) {
            names.removeAll()
        } else {
            for drop in drops {
                if let capability = try? CapabilityName(rawValue: drop) { names.remove(capability) }
            }
        }
        let adds = security.capabilities.addCapabilities
        if adds.contains(where: { $0.uppercased() == "ALL" }) {
            return .allCapabilities
        }
        for add in adds {
            if let capability = try? CapabilityName(rawValue: add) { names.insert(capability) }
        }

        let list = Array(names)
        // Ambient is left empty: capabilities are granted to the container's
        // own process, not inherited by anything it later executes.
        return Containerization.LinuxCapabilities(
            bounding: list, effective: list, inheritable: list, permitted: list, ambient: [])
    }

    /// Asks ferry-streamer which containers the pod spec declares. A failure is
    /// not fatal: without it single-container pods behave exactly as before,
    /// only sidecars are lost.
    private func podContainers(namespace: String, name: String) async -> (initContainers: [String], containers: [String]) {
        guard !namespace.isEmpty, !name.isEmpty, let streamer else { return ([], []) }
        do {
            let body = try streamer.get(path: "/pod?namespace=\(namespace)&name=\(name)")
            let decoded = try JSONDecoder().decode(PodContainers.self, from: body)
            return (decoded.initContainers ?? [], decoded.containers ?? [])
        } catch {
            return ([], [])
        }
    }

    private func makePod(id: String, interface: any Interface,
                         cfg: Runtime_V1_PodSandboxConfig,
                         clusterInterface: SwitchInterface? = nil) throws -> LinuxPod {
        try LinuxPod(id, vmm: VZVirtualMachineManager(kernel: kernel, initialFilesystem: initfs)) { c in
            c.cpus = config.defaultCPUs
            c.memoryInBytes = config.defaultMemoryBytes
            // eth0 is vmnet and keeps the default route; eth1, when there is a
            // cluster, is ferry's own segment.
            c.interfaces = clusterInterface.map { [interface, $0] } ?? [interface]
            c.hostname = cfg.hostname.isEmpty ? cfg.metadata.name : cfg.hostname
            if !cfg.dnsConfig.servers.isEmpty {
                c.dns = DNS(nameservers: cfg.dnsConfig.servers,
                            domain: cfg.dnsConfig.searches.first,
                            searchDomains: cfg.dnsConfig.searches,
                            options: cfg.dnsConfig.options)
            }
        }
    }

    func stopPodSandbox(_ id: String) async throws {
        guard var record = sandboxes[id] else { throw RuntimeFailure.notFound("sandbox \(id)") }
        guard record.ready else { return }
        let wasBooted = record.booted
        for containerID in containers.values.filter({ $0.sandboxID == id }).map(\.id) {
            containers[containerID]?.state = .exited
            containers[containerID]?.finishedAt = Self.now()
        }
        if wasBooted { try? await record.pod.stop() }
        record.ready = false
        // Free the reserved DNS address as soon as the pod stops. Waiting for
        // RemovePodSandbox lets a terminated CoreDNS keep the reservation, so
        // its replacement lands on an ordinary address and the kubelet's
        // clusterDNS then points at nothing.
        if record.usesReservedAddress { dnsInterfaceInUse = false; clusterDNSInUse = false }
        podSwitch?.detach(podID: id)
        defer { publishHostReachableMap() }
        if let address = record.clusterAddress { clusterAddresses?.give(back: address) }
        sandboxes[id] = record
    }

    func removePodSandbox(_ id: String) async throws {
        guard sandboxes[id] != nil else { return }
        try? await stopPodSandbox(id)
        for containerID in containers.values.filter({ $0.sandboxID == id }).map(\.id) {
            containers.removeValue(forKey: containerID)
        }
        // The reserved DNS address stays reserved across CoreDNS restarts; only
        // ordinary pod addresses go back to the allocator.
        if sandboxes[id]?.usesReservedAddress == true {
            dnsInterfaceInUse = false
        } else {
            try? network.releaseInterface(id)
        }
        sandboxes.removeValue(forKey: id)
    }

    func sandbox(_ id: String) throws -> SandboxRecord {
        guard let record = sandboxes[id] else { throw RuntimeFailure.notFound("sandbox \(id)") }
        return record
    }

    func listSandboxes() -> [SandboxRecord] { Array(sandboxes.values) }

    // MARK: - Service rules
    //
    // The ruleset is computed once on the host and applied inside each pod.
    // That is the whole reason there is no kube-proxy here: a pod needs the
    // rules, not a process that works them out for itself.

    /// The pod network, when ferry is running one.
    private var podSwitch: PodSwitch?
    private var clusterAddresses: RotatingAddresses?
    private var clusterDNSAddress: String?
    private var clusterDNSInUse = false

    private var lastRuleset: Data?
    private var lastGeneration: UInt64 = 0
    /// NetworkPolicy rules, one section per pod address.
    private var policyRules: [String: String] = [:]
    private var lastPolicyGeneration: UInt64 = 0

    /// One rule kube-proxy cannot know it needs.
    ///
    /// A pod reaches a ClusterIP through its default route, which is eth0 on
    /// vmnet, so the kernel picks eth0's address as the source before anything
    /// is rewritten. kube-proxy then DNATs the destination to a pod address, and
    /// the packet correctly leaves by eth1 -- still carrying a vmnet source.
    ///
    /// On one machine that survives, because the reply finds its way back over
    /// the vmnet network the pods share. Across machines it cannot: the other
    /// Mac's pods have never heard of this one's vmnet addresses, and the reply
    /// goes nowhere.
    ///
    /// Masquerading what leaves eth1 with a source from outside the cluster
    /// network fixes it, and does so without losing anything: masquerade takes
    /// the outgoing interface's address, which is the pod's own cluster address.
    /// The peer still sees the pod it is actually talking to.
    private func ferryEgressRule() -> String? {
        guard let cidr = config.clusterCIDR else { return nil }
        return """
        add chain ip kube-proxy ferry-egress { type nat hook postrouting priority 110 ; }
        add rule ip kube-proxy ferry-egress oifname "eth1" ip saddr != \(cidr) masquerade

        """
    }

    /// Applies the current ruleset to one pod. Quiet on failure: a pod that
    /// cannot reach Services is worth a log line, not a failed start.
    func applyServiceRules(sandboxID: String, ruleset: Data) async {
        var payload = ruleset
        if let extra = ferryEgressRule(), let bytes = extra.data(using: .utf8) {
            payload.append(bytes)
        }
        await applyNftables(sandboxID: sandboxID, payload: payload, label: "Service")
    }

    func applyNftables(sandboxID: String, text: String, label: String) async {
        guard let payload = text.data(using: .utf8) else { return }
        await applyNftables(sandboxID: sandboxID, payload: payload, label: label)
    }

    /// Loads an nftables script into one pod's own kernel.
    ///
    /// Everything ferry does to a pod's networking goes through here: the
    /// Service rules kube-proxy rendered, and the NetworkPolicy rules meant for
    /// this pod alone. Both are text, and the pod has a kernel to put them in.
    private func applyNftables(sandboxID: String, payload: Data, label: String) async {
        guard config.nftBundlePath != nil, !payload.isEmpty else { return }
        guard let target = containers.values.first(where: {
            $0.sandboxID == sandboxID && $0.state == .running
        }) else { return }

        do {
            // nft needs NET_ADMIN to program the pod's kernel, and an ordinary
            // pod does not ask for it. Granting it to this process rather than
            // to the container keeps the privilege on a binary ferry ships and
            // runs, not on the workload.
            var privileged = Containerization.LinuxCapabilities.defaultOCICapabilities
            if let netAdmin = try? CapabilityName(rawValue: "NET_ADMIN") {
                privileged.bounding.append(netAdmin)
                privileged.effective.append(netAdmin)
                privileged.permitted.append(netAdmin)
            }

            let process = try await exec(
                containerID: target.id,
                // Invoked through its own loader so the pod's libc is irrelevant.
                command: ["/.ferry/lib/ld-musl-aarch64.so.1",
                          "--library-path", "/.ferry/lib",
                          "/.ferry/nft", "-f", "-"],
                tty: false,
                stdin: DataReaderStream(payload),
                stdout: DiscardWriter(),
                stderr: ErrorWriter(prefix: "nft"),
                capabilities: privileged
            )
            try await process.start()
            _ = try? await process.wait(timeoutInSeconds: 15)
        } catch {
            FileHandle.standardError.write(
                "warning: could not program \(label) rules in \(sandboxID): \(error)\n".data(using: .utf8)!)
        }
    }

    /// The generation last applied, so the caller can ask for something newer.
    func seenGeneration() -> UInt64 { lastGeneration }

    /// Takes a freshly fetched ruleset and puts it in every running pod.
    ///
    /// The fetch deliberately happens outside this actor. It is a blocking read
    /// held open by ferry-proxyd until a Service changes, which can be tens of
    /// seconds; doing it here would park the actor for that whole time and every
    /// CRI call behind it -- a pod would not start or stop while ferry waited
    /// for news that may never come.
    func applyRuleset(_ ruleset: Data, generation: UInt64) async {
        guard config.nftBundlePath != nil, !ruleset.isEmpty else { return }
        lastGeneration = generation
        guard ruleset != lastRuleset else { return }
        lastRuleset = ruleset
        for sandbox in sandboxes.values where sandbox.booted {
            await applyServiceRules(sandboxID: sandbox.id, ruleset: ruleset)
        }
    }

    /// The ruleset as it stands, for a pod that has just booted.
    func currentRuleset() -> Data? { lastRuleset }

    /// What ferry-netpol last said about this pod, if anything.
    func currentPolicy(forPodAt address: String) -> String? { policyRules[address] }

    func seenPolicyGeneration() -> UInt64 { lastPolicyGeneration }

    /// Takes a fresh set of policy rules and puts each pod's own section into it.
    ///
    /// A NetworkPolicy is per pod, so unlike the Service ruleset these differ
    /// from one pod to the next and cannot be broadcast. The document is split
    /// by address and each running pod gets its part.
    func applyPolicies(_ document: String, generation: UInt64) async {
        lastPolicyGeneration = generation
        var sections: [String: String] = [:]
        var address = ""
        var body = ""
        for line in document.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                if !address.isEmpty { sections[address] = body }
                address = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                body = ""
            } else {
                body += line + "\n"
            }
        }
        if !address.isEmpty { sections[address] = body }

        for (podAddress, rules) in sections where policyRules[podAddress] != rules {
            policyRules[podAddress] = rules
            guard let sandbox = sandboxes.values.first(where: { $0.ip == podAddress && $0.booted })
            else { continue }
            await applyNftables(sandboxID: sandbox.id, text: rules, label: "policy")
        }
        // A pod that vanished from the document has no policy to enforce.
        for known in policyRules.keys where sections[known] == nil {
            policyRules.removeValue(forKey: known)
        }
    }

    func cacheRuleset(_ ruleset: Data, generation: UInt64) {
        guard !ruleset.isEmpty else { return }
        lastRuleset = ruleset
        lastGeneration = generation
    }

    /// Where to fetch rulesets from, for the loop that does it off-actor.
    nonisolated var proxydClient: StreamerClient? {
        config.proxydSocket.map { StreamerClient(socketPath: $0) }
    }

    nonisolated var netpolClient: StreamerClient? {
        config.netpolSocket.map { StreamerClient(socketPath: $0) }
    }

    /// Everything attach needs: the output fan-out point, the stdin feeder if
    /// the pod asked for one, and whether the container was given a terminal.
    func attachTargets(_ id: String) throws -> (output: ContainerLogFile, stdin: FrameReaderStream?, tty: Bool) {
        guard let record = containers[id] else { throw RuntimeFailure.notFound("container \(id)") }
        guard record.state == .running else {
            throw RuntimeFailure.invalid("container \(id) is not running")
        }
        guard let output = record.logFile else {
            throw RuntimeFailure.unsupported("container \(id) has no output stream to attach to")
        }
        return (output, record.stdinFeeder, record.tty)
    }

    /// The pod's address, for port forwarding. ferry-streamer dials it directly.
    /// Where the *Mac* can reach this pod.
    ///
    /// Not the same as the pod IP once there is a cluster network: that address
    /// is on ferry's switch, which carries traffic between pods and which the
    /// host is not on. port-forward and the host side of a Service both run on
    /// the Mac, so both want the vmnet address.
    func sandboxAddress(_ id: String) -> String? {
        guard let record = sandboxes[id] else { return nil }
        return record.hostAddress.isEmpty ? record.ip : record.hostAddress
    }

    private func publishHostReachableMap() {
        try? hostReachableMap().write(
            to: config.stateDir.appending(component: "podmap"),
            atomically: true, encoding: .utf8)
    }

    /// Every pod on this node as "<pod IP> <address the Mac can reach it at>".
    /// ferry-proxy reads this to turn an endpoint into something it can dial.
    func hostReachableMap() -> String {
        sandboxes.values
            .filter { !$0.hostAddress.isEmpty && $0.ip != $0.hostAddress }
            .map { "\($0.ip) \($0.hostAddress)" }
            .sorted()
            .joined(separator: "\n") + "\n"
    }

    // MARK: - Containers

    func createContainer(
        sandboxID: String,
        config cfg: Runtime_V1_ContainerConfig
    ) async throws -> String {
        guard let sandbox = sandboxes[sandboxID] else { throw RuntimeFailure.notFound("sandbox \(sandboxID)") }
        let imageRef = cfg.image.image
        // The kubelet resolves an image to its ID before calling
        // CreateContainer, so the lookup has to work by digest as well as by
        // the reference the pull used.
        guard let base = rootfsCache[imageRef] ?? rootfsCache[ImageReference.normalize(imageRef)] else {
            throw RuntimeFailure.notFound("image \(imageRef) has not been pulled")
        }

        if sandbox.booted {
            // The kubelet retries CreateContainer after a container fails to
            // start, and this hypervisor cannot add one to a running VM. If
            // nothing is running in the pod there is nothing to preserve, so
            // rebuild the VM rather than leaving the pod permanently stuck.
            let live = containers.values.contains { $0.sandboxID == sandboxID && $0.state == .running }
            if live {
                throw RuntimeFailure.unsupported("""
                    cannot add a container to a pod that is already running: \
                    Virtualization.framework does not support hotplug, so every \
                    container in a pod must be created before the first one starts
                    """)
            }
            try? await sandbox.pod.stop()
            for stale in containers.values.filter({ $0.sandboxID == sandboxID }) {
                try? FileManager.default.removeItem(
                    atPath: config.stateDir.appending(component: "\(stale.id).ext4").path())
                containers.removeValue(forKey: stale.id)
            }
            let rebuilt = try makePod(id: sandboxID, interface: sandbox.interface, cfg: sandbox.config)
            sandboxes[sandboxID]?.pod = rebuilt
            sandboxes[sandboxID]?.booted = false
        }
        // Re-read: the record may have just been rebuilt.
        guard let sandbox = sandboxes[sandboxID] else {
            throw RuntimeFailure.notFound("sandbox \(sandboxID)")
        }

        let id = nextID("ctr")
        // Each container needs a writable root of its own; the cached unpack is
        // shared and must stay pristine. Clear any leftover at the destination
        // first: clone fails if it exists, and it can exist because container
        // ids restart from zero when ferry-cri does, while the files under the
        // state directory persist.
        let clonePath = config.stateDir.appending(component: "\(id).ext4").path()
        try? FileManager.default.removeItem(atPath: clonePath)
        let rootfs = try base.clone(to: clonePath)

        // Merge the pod's overrides with the image's own configuration, the way
        // Kubernetes defines it: `command` replaces ENTRYPOINT, `args` replaces
        // CMD, and anything not overridden comes from the image.
        let imageConfig = imageConfigs[imageRef] ?? imageConfigs[ImageReference.normalize(imageRef)]
        let entrypoint = cfg.command.isEmpty ? (imageConfig?.entrypoint ?? []) : cfg.command
        let commandArgs: [String]
        if !cfg.args.isEmpty {
            commandArgs = cfg.args
        } else if cfg.command.isEmpty {
            // Only inherit CMD when the pod overrode neither; a pod that sets
            // `command` alone must not pick up the image's CMD.
            commandArgs = imageConfig?.cmd ?? []
        } else {
            commandArgs = []
        }
        let combined = entrypoint + commandArgs
        let arguments = combined.isEmpty ? ["/bin/sh"] : combined

        // Image environment first so the pod's values win on conflict.
        var mergedEnv = imageConfig?.env ?? []
        for entry in cfg.envs { 
            mergedEnv.removeAll { $0.hasPrefix("\(entry.key)=") }
            mergedEnv.append("\(entry.key)=\(entry.value)")
        }
        let environment = mergedEnv
        let workingDir = cfg.workingDir.isEmpty ? (imageConfig?.workingDir ?? "") : cfg.workingDir

        // Security context and resource limits, both carried in
        // ContainerConfig.linux. The kubelet only fills that section in from
        // applyPlatformSpecificContainerConfig, which upstream builds for linux
        // and windows only; ferry's kubelet derives a darwin copy so pods get
        // their limits and capabilities. See build-kubelet.sh.
        let security = cfg.linux.securityContext
        let capabilities = Self.capabilities(for: security)
        let runAsUser = security.hasRunAsUser ? UInt32(security.runAsUser.value) : nil
        let runAsGroup = security.hasRunAsGroup ? UInt32(security.runAsGroup.value) : nil
        let memoryLimit = cfg.linux.resources.memoryLimitInBytes
        let cpuQuota = cfg.linux.resources.cpuQuota
        let cpuPeriod = cfg.linux.resources.cpuPeriod

        // The kubelet assembles volume contents on the host -- projected
        // ServiceAccount tokens, ConfigMaps, Secrets, emptyDir -- and passes
        // the directories here. Share each one into the guest over virtiofs.
        // These become VM devices, which is why they can only be attached
        // before the pod boots.
        var collected: [Containerization.Mount] = []
        for mount in cfg.mounts {
            guard !mount.hostPath.isEmpty, !mount.containerPath.isEmpty else { continue }
            guard FileManager.default.fileExists(atPath: mount.hostPath) else {
                // A path the kubelet has not created yet is a bug on our side
                // if we silently skip it, so say so rather than starting a pod
                // that is quietly missing its token.
                throw RuntimeFailure.invalid("mount source \(mount.hostPath) does not exist")
            }
            collected.append(.share(
                source: mount.hostPath,
                destination: mount.containerPath,
                options: mount.readonly ? ["ro"] : []
            ))
        }
        // Every pod gets nft, so Service rules are applied inside its own kernel
        // rather than proxied through the host. The bundle carries its own musl
        // loader, so it does not matter what the pod's image is built on.
        if let bundle = config.nftBundlePath, FileManager.default.fileExists(atPath: bundle) {
            collected.append(.share(source: bundle, destination: "/.ferry", options: ["ro"]))
        }

        // Immutable so it can cross into the configuration closure.
        let shares = collected

        // CRI gives a log path relative to the sandbox's log directory; the
        // kubelet reads exactly this file for `kubectl logs`.
        var writers: [ContainerLogWriter] = []
        var logFile: ContainerLogFile?
        var stdoutWriter: ContainerLogWriter?
        var stderrWriter: ContainerLogWriter?
        // ContainerConfig.logPath is relative to the sandbox log directory, but
        // ContainerStatus.logPath must be absolute -- the kubelet resolves the
        // latter directly, and a relative value makes `kubectl logs` fail with
        // a confusing lstat error.
        var absoluteLogPath = ""
        if !cfg.logPath.isEmpty && !sandbox.logDirectory.isEmpty {
            let full = URL(filePath: sandbox.logDirectory).appending(path: cfg.logPath).path()
            absoluteLogPath = full
            let file = try ContainerLogFile(path: full)
            logFile = file
            stdoutWriter = ContainerLogWriter(file: file, stream: .stdout)
            stderrWriter = ContainerLogWriter(file: file, stream: .stderr)
            writers = [stdoutWriter!, stderrWriter!]
        }
        let outWriter = stdoutWriter
        let errWriter = stderrWriter

        let stdinFeeder = cfg.stdin ? FrameReaderStream() : nil

        try await sandbox.pod.addContainer(id, rootfs: rootfs) { c in
            c.process.arguments = arguments
            c.process.terminal = cfg.tty
            if let stdinFeeder { c.process.stdin = stdinFeeder }
            if let outWriter { c.process.stdout = outWriter }
            if let errWriter { c.process.stderr = errWriter }
            c.process.capabilities = capabilities
            if let runAsUser { c.process.user.uid = runAsUser }
            if let runAsGroup { c.process.user.gid = runAsGroup }
            if !environment.isEmpty { c.process.environmentVariables = environment }
            if !workingDir.isEmpty { c.process.workingDirectory = workingDir }
            if memoryLimit > 0 { c.memoryInBytes = UInt64(memoryLimit) }
            if cpuQuota > 0 && cpuPeriod > 0 { c.cpus = max(1, Int(cpuQuota / cpuPeriod)) }
            // Append rather than replace: the defaults carry /proc, /sys and
            // the rest of the standard container filesystem.
            c.mounts.append(contentsOf: shares)
        }

        containers[id] = ContainerRecord(
            id: id, sandboxID: sandboxID,
            name: cfg.metadata.name, attempt: cfg.metadata.attempt,
            // CRI asks for two different things here: `image` is the name the
            // pod was written with, `imageRef` identifies the bytes. The kubelet
            // has already resolved the first into the second by this point, so
            // the name is recovered from what the pull recorded -- otherwise
            // kubectl reports every container as running a bare digest.
            image: pulledImages[imageRef]?.repoTags.last ?? imageRef,
            imageRef: pulledImages[imageRef]?.id ?? imageRef,
            labels: cfg.labels, annotations: cfg.annotations,
            logPath: absoluteLogPath, createdAt: Self.now(), tty: cfg.tty,
            logWriters: writers, logFile: logFile, stdinFeeder: stdinFeeder
        )
        return id
    }

    func startContainer(_ id: String) async throws {
        guard let record = containers[id] else { throw RuntimeFailure.notFound("container \(id)") }
        guard let sandbox = sandboxes[record.sandboxID] else {
            throw RuntimeFailure.notFound("sandbox \(record.sandboxID)")
        }

        if !sandbox.booted {
            // The kubelet works through a pod's containers one at a time --
            // create, start, create, start -- and this hypervisor cannot add a
            // container to a running VM. Booting on the first start therefore
            // locks out every later container, which is what made sidecars
            // impossible. Instead the boot waits until the pod's whole regular
            // container set has been created.
            //
            // Init containers are exempt: the kubelet runs them one at a time
            // by design, each exiting before the next is created, so each gets
            // its own VM.
            let isInit = sandbox.initContainerNames.contains(record.name)
            let expected = sandbox.expectedContainers
            let created = Set(containers.values
                .filter { $0.sandboxID == record.sandboxID }
                .map(\.name))
            let complete = expected.isEmpty || isInit || expected.allSatisfy { created.contains($0) }

            if !complete {
                // Report success and start it once the VM is up. The kubelet
                // polls container status, so it sees the container running a
                // moment later rather than being told it failed.
                sandboxes[record.sandboxID]?.pendingStart.append(id)
                return
            }

            try await sandbox.pod.create()
            sandboxes[record.sandboxID]?.booted = true

            for waiting in sandboxes[record.sandboxID]?.pendingStart ?? [] where waiting != id {
                try? await sandbox.pod.startContainer(waiting)
                markStarted(waiting, pod: sandbox.pod)
            }
            sandboxes[record.sandboxID]?.pendingStart = []
        }

        try await sandbox.pod.startContainer(id)
        markStarted(id, pod: sandbox.pod)

        // A pod cannot reach a Service until its own kernel has the rules, and
        // it should not be reachable past its policy before it has those either.
        let sandboxID = record.sandboxID
        let address = sandboxes[sandboxID]?.ip ?? ""
        if let ruleset = lastRuleset {
            Task { [weak self] in await self?.applyServiceRules(sandboxID: sandboxID, ruleset: ruleset) }
        }
        if let policy = policyRules[address] {
            Task { [weak self] in
                await self?.applyNftables(sandboxID: sandboxID, text: policy, label: "policy")
            }
        }
    }

    private func markStarted(_ id: String, pod: LinuxPod) {
        containers[id]?.state = .running
        containers[id]?.startedAt = Self.now()

        // Reap asynchronously so the exit code is available to ContainerStatus
        // without the kubelet having to ask the pod directly.
        Task { [weak self] in
            let status = try? await pod.waitContainer(id)
            await self?.recordExit(id, code: status?.exitCode ?? -1)
        }
    }

    private func recordExit(_ id: String, code: Int32) {
        guard containers[id] != nil else { return }
        // Flush whatever the container wrote without a trailing newline.
        for writer in containers[id]?.logWriters ?? [] { try? writer.close() }
        containers[id]?.logFile?.close()
        containers[id]?.state = .exited
        containers[id]?.exitCode = code
        containers[id]?.finishedAt = Self.now()
    }

    func stopContainer(_ id: String, timeout: Int64) async throws {
        guard let record = containers[id] else { throw RuntimeFailure.notFound("container \(id)") }
        guard record.state == .running else { return }
        if let sandbox = sandboxes[record.sandboxID] {
            try? await sandbox.pod.stopContainer(id)
        }
        recordExit(id, code: 0)
    }

    func removeContainer(_ id: String) async throws {
        guard let record = containers[id] else { return }
        if record.state == .running { try? await stopContainer(id, timeout: 0) }
        try? FileManager.default.removeItem(atPath: config.stateDir.appending(component: "\(id).ext4").path())
        containers.removeValue(forKey: id)
    }

    /// Runs a command in a container's VM for `kubectl exec`. An empty command
    /// means attach, which is not supported yet -- the framework exposes no way
    /// to reattach to a process that is already running.
    func exec(
        containerID: String,
        command: [String],
        tty: Bool,
        stdin: (any ReaderStream)?,
        stdout: any Writer,
        stderr: any Writer,
        capabilities: Containerization.LinuxCapabilities? = nil
    ) async throws -> LinuxProcess {
        guard let record = containers[containerID] else {
            throw RuntimeFailure.notFound("container \(containerID)")
        }
        guard let sandbox = sandboxes[record.sandboxID], sandbox.booted else {
            throw RuntimeFailure.invalid("container \(containerID) is not running")
        }
        guard !command.isEmpty else {
            throw RuntimeFailure.unsupported("attach is not implemented; use kubectl exec")
        }

        idCounter += 1
        let processID = String(format: "exec%012llx", idCounter)
        return try await sandbox.pod.execInContainer(containerID, processID: processID) { config in
            config.arguments = command
            config.terminal = tty
            config.stdin = stdin
            config.stdout = stdout
            // With a TTY there is one stream, and the client expects everything
            // on stdout; sending stderr separately would interleave badly.
            config.stderr = tty ? nil : stderr
            if let capabilities { config.capabilities = capabilities }
        }
    }

    func reopenContainerLog(_ id: String) throws {
        guard let record = containers[id] else { throw RuntimeFailure.notFound("container \(id)") }
        try record.logFile?.reopen()
    }

    func container(_ id: String) throws -> ContainerRecord {
        guard let record = containers[id] else { throw RuntimeFailure.notFound("container \(id)") }
        return record
    }

    func listContainers() -> [ContainerRecord] { Array(containers.values) }

    // MARK: - Images

    /// Takes images from an OCI layout on disk instead of a registry.
    ///
    /// This is how someone runs code they have just built. Everything else in
    /// ferry comes from a registry, which is fine for busybox and useless for
    /// the thing you are working on -- `minikube image load` and `kind load
    /// docker-image` exist for exactly this reason.
    ///
    /// The image is registered under the name it carries, so a manifest that
    /// says `myapp:dev` keeps saying that. Pulling is what has to be avoided:
    /// the kubelet is told the image is present, and `imagePullPolicy: Never`
    /// or `IfNotPresent` keeps it from going to look for a registry that has
    /// never heard of it.
    func loadImages(from directory: String) async throws -> [String] {
        guard !directory.isEmpty else {
            throw RuntimeFailure.invalid("no directory to load from")
        }
        let platform = ContainerizationOCI.Platform(arch: "arm64", os: "linux", variant: "v8")
        let images = try await store.load(from: URL(filePath: directory))
        var loaded: [String] = []
        for image in images {
            // Unpack now rather than at first use: a pod that has to wait for a
            // root filesystem to be built looks like a pod that is stuck.
            let canonical = ImageReference.normalize(image.reference)
            _ = try? await cache(image, as: Set([image.reference, canonical]),
                                 canonical: canonical, platform: platform)
            loaded.append(image.reference)
        }
        guard !loaded.isEmpty else {
            throw RuntimeFailure.invalid("no images found in \(directory)")
        }
        return loaded
    }

    func pullImage(_ reference: String) async throws -> String {
        let platform = ContainerizationOCI.Platform(arch: "arm64", os: "linux", variant: "v8")
        // The registry is asked for the fully qualified name; every cache is
        // keyed by both that and whatever the manifest actually said, so a pod
        // written as `busybox:1.36` finds the image it just pulled.
        let canonical = ImageReference.normalize(reference)
        let image = try await store.pull(reference: canonical, platform: platform)
        return try await cache(image, as: Set([reference, canonical]), canonical: canonical,
                               platform: platform)
    }

    /// Unpacks an image to a root filesystem and records it where the kubelet
    /// will look. Shared by pulling and loading, which differ only in where the
    /// image came from.
    private func cache(_ image: Containerization.Image, as keys: Set<String>, canonical: String,
                       platform: ContainerizationOCI.Platform) async throws -> String {

        if rootfsCache[canonical] == nil {
            let safe = canonical.replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
            let path = config.stateDir.appending(component: "image-\(safe).ext4")
            let mount: Containerization.Mount
            do {
                mount = try await EXT4Unpacker(capacityInBytes: 2.gib())
                    .unpack(image, for: platform, at: path)
            } catch let error as ContainerizationError where error.code == .exists {
                mount = .block(format: "ext4", source: path.path(), destination: "/", options: [])
            }
            for key in keys { rootfsCache[key] = mount }
            if !image.digest.isEmpty { rootfsCache[image.digest] = mount }
        } else {
            for key in keys { rootfsCache[key] = rootfsCache[canonical] }
        }

        if let imageConfig = try? await image.config(for: platform).config {
            for key in keys { imageConfigs[key] = imageConfig }
            if !image.digest.isEmpty { imageConfigs[image.digest] = imageConfig }
        }

        // The kubelet rejects an image whose id or size is unset -- it reports
        // ImageInspectError and the pod never starts. Size is taken from the
        // unpacked root filesystem, which is the thing that actually occupies
        // disk in this runtime.
        let digest = image.digest.isEmpty ? canonical : image.digest
        var size: UInt64 = 0
        if let mount = rootfsCache[canonical],
           let attrs = try? FileManager.default.attributesOfItem(atPath: mount.source),
           let bytes = attrs[.size] as? UInt64 {
            size = bytes
        }

        var entry = Runtime_V1_Image()
        entry.id = digest
        entry.repoTags = Array(keys).sorted()
        entry.repoDigests = image.digest.isEmpty ? [] : ["\(canonical)@\(image.digest)"]
        entry.size = max(size, 1)
        for key in keys { pulledImages[key] = entry }
        if !image.digest.isEmpty { pulledImages[image.digest] = entry }
        return digest
    }

    func imageStatus(_ reference: String) -> Runtime_V1_Image? {
        pulledImages[reference] ?? pulledImages[ImageReference.normalize(reference)]
    }
    func listImages() -> [Runtime_V1_Image] { Array(pulledImages.values) }

    func removeImage(_ reference: String) {
        for key in Set([reference, ImageReference.normalize(reference)]) {
            pulledImages.removeValue(forKey: key)
            rootfsCache.removeValue(forKey: key)
            imageConfigs.removeValue(forKey: key)
        }
    }

    /// Stops every pod and releases every address. Without this the vmnet
    /// network outlives the process briefly, and the next ferry-cri to claim
    /// the same subnet fails with VMNET_FAILURE.
    func shutdown() async {
        for record in sandboxes.values {
            try? await record.pod.stop()
            try? network.releaseInterface(record.id)
        }
        sandboxes.removeAll()
        containers.removeAll()
    }

    func dnsAddress() -> String? {
        guard let dnsInterface else { return nil }
        return "\(dnsInterface.ipv4Address)".split(separator: "/").first.map(String.init)
    }

    func stateDirPath() -> String { config.stateDir.path() }

    func stateDirUsage() -> (capacity: UInt64, used: UInt64, inodes: UInt64) {
        var st = statfs()
        guard statfs(config.stateDir.path(), &st) == 0 else { return (0, 0, 0) }
        let block = UInt64(st.f_bsize)
        return (UInt64(st.f_blocks) * block, UInt64(st.f_blocks - st.f_bfree) * block, UInt64(st.f_files))
    }
}
