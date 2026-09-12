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
import Foundation
import Synchronization

struct RuntimeConfig: Sendable {
    var stateDir: URL
    var kernelPath: String
    var podSubnet: String
    var initImage: String
    var defaultCPUs: Int
    var defaultMemoryBytes: UInt64
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
    let pod: LinuxPod
    let name: String
    let uid: String
    let namespace: String
    let attempt: UInt32
    let labels: [String: String]
    let annotations: [String: String]
    let ip: String
    let createdAt: Int64
    var ready: Bool = true
    /// Whether the VM has been booted. Virtualization.framework cannot hotplug,
    /// so containers must all be added before `create()`; the VM is therefore
    /// booted lazily on the first StartContainer rather than at RunPodSandbox.
    var booted: Bool = false
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

    private var sandboxes: [String: SandboxRecord] = [:]
    private var containers: [String: ContainerRecord] = [:]

    /// Unpacked, read-only root filesystems keyed by image reference. Each
    /// container gets a writable clone of one of these rather than unpacking
    /// the image again.
    private var rootfsCache: [String: Containerization.Mount] = [:]
    private var pulledImages: [String: Runtime_V1_Image] = [:]

    private var idCounter: UInt64 = 0

    init(config: RuntimeConfig) throws {
        self.config = config
        try FileManager.default.createDirectory(at: config.stateDir, withIntermediateDirectories: true)
        self.store = try ImageStore(path: config.stateDir)
        self.kernel = Kernel(path: URL(filePath: config.kernelPath), platform: .linuxArm)
    }

    /// Pulls the guest agent image and creates the pod network. Kept out of
    /// init so failures surface with context before the server starts serving.
    func prepare() async throws {
        let initImage = try await store.getInitImage(reference: config.initImage)
        let initPath = config.stateDir.appending(component: "init.ext4")
        do {
            self.initfs = try await initImage.initBlock(at: initPath, for: .linuxArm)
        } catch let error as ContainerizationError where error.code == .exists {
            self.initfs = .block(format: "ext4", source: initPath.path(), destination: "/", options: ["ro"])
        }
        // vmnet networks are not always reclaimed when the process that made
        // them exits -- a subnet can stay claimed with nothing holding it, and
        // stays that way. So try the configured subnet first and fall back
        // through candidates rather than refusing to start.
        var chosen: VmnetNetwork?
        var lastError: Error?
        for candidate in Self.subnetCandidates(preferred: config.podSubnet) {
            do {
                chosen = try VmnetNetwork(subnet: try CIDRv4(candidate))
                if candidate != config.podSubnet {
                    print("    \(config.podSubnet) is claimed by a leaked network; using \(candidate)")
                }
                lastError = nil
                break
            } catch {
                lastError = error
            }
        }
        guard let chosen else { throw lastError ?? RuntimeFailure.unsupported("no pod subnet available") }
        self.network = chosen

        // The API server has to advertise the gateway of whichever subnet was
        // actually obtained, so publish it for whoever starts the control plane.
        try? "\(chosen.ipv4Gateway)\n".write(
            to: config.stateDir.appending(component: "gateway"),
            atomically: true, encoding: .utf8)
    }

    var gateway: String { "\(network.ipv4Gateway)" }
    var subnet: String { "\(network.subnet)" }

    /// The preferred subnet first, then a spread of alternatives for when it
    /// has been leaked by an earlier run.
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
        guard let interface = try network.createInterface(id) else {
            throw RuntimeFailure.invalid("pod network exhausted; no address available")
        }
        let ip = "\(interface.ipv4Address)".split(separator: "/").first.map(String.init) ?? ""

        // Kubernetes sends resource limits per container, not per sandbox, so
        // the VM is sized from defaults here and containers are bounded inside
        // it by cgroups. Right-sizing the VM from the pod's aggregate requests
        // is a worthwhile refinement, not a correctness issue.
        let pod = try LinuxPod(id, vmm: VZVirtualMachineManager(kernel: kernel, initialFilesystem: initfs)) { c in
            c.cpus = config.defaultCPUs
            c.memoryInBytes = config.defaultMemoryBytes
            c.interfaces = [interface]
            c.hostname = cfg.hostname.isEmpty ? cfg.metadata.name : cfg.hostname
            if !cfg.dnsConfig.servers.isEmpty {
                c.dns = DNS(nameservers: cfg.dnsConfig.servers,
                            domain: cfg.dnsConfig.searches.first,
                            searchDomains: cfg.dnsConfig.searches,
                            options: cfg.dnsConfig.options)
            }
        }
        // Deliberately not created yet. CRI adds containers after the sandbox
        // exists, and on this hypervisor a container can only be added before
        // the VM boots -- see startContainer.

        sandboxes[id] = SandboxRecord(
            id: id, pod: pod,
            name: cfg.metadata.name, uid: cfg.metadata.uid,
            namespace: cfg.metadata.namespace, attempt: cfg.metadata.attempt,
            labels: cfg.labels, annotations: cfg.annotations,
            ip: ip, createdAt: Self.now()
        )
        return id
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
        sandboxes[id] = record
    }

    func removePodSandbox(_ id: String) async throws {
        guard sandboxes[id] != nil else { return }
        try? await stopPodSandbox(id)
        for containerID in containers.values.filter({ $0.sandboxID == id }).map(\.id) {
            containers.removeValue(forKey: containerID)
        }
        try? network.releaseInterface(id)
        sandboxes.removeValue(forKey: id)
    }

    func sandbox(_ id: String) throws -> SandboxRecord {
        guard let record = sandboxes[id] else { throw RuntimeFailure.notFound("sandbox \(id)") }
        return record
    }

    func listSandboxes() -> [SandboxRecord] { Array(sandboxes.values) }

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
        guard let base = rootfsCache[imageRef] else {
            throw RuntimeFailure.notFound("image \(imageRef) has not been pulled")
        }

        if sandbox.booted {
            throw RuntimeFailure.unsupported("""
                cannot add a container to a pod whose VM is already running: \
                Virtualization.framework does not support hotplug, so every \
                container in a pod must be created before the first one starts
                """)
        }

        let id = nextID("ctr")
        // Each container needs a writable root of its own; the cached unpack is
        // shared and must stay pristine.
        let clonePath = config.stateDir.appending(component: "\(id).ext4").path()
        let rootfs = try base.clone(to: clonePath)

        // Immutable so the value can cross into the configuration closure,
        // which runs concurrently.
        let combined = cfg.command + cfg.args
        let arguments = combined.isEmpty ? ["/bin/sh"] : combined
        let environment = cfg.envs.map { "\($0.key)=\($0.value)" }
        let workingDir = cfg.workingDir
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
        // Immutable so it can cross into the configuration closure.
        let shares = collected

        try await sandbox.pod.addContainer(id, rootfs: rootfs) { c in
            c.process.arguments = arguments
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
            image: imageRef, imageRef: imageRef,
            labels: cfg.labels, annotations: cfg.annotations,
            logPath: cfg.logPath, createdAt: Self.now()
        )
        return id
    }

    func startContainer(_ id: String) async throws {
        guard let record = containers[id] else { throw RuntimeFailure.notFound("container \(id)") }
        guard let sandbox = sandboxes[record.sandboxID] else {
            throw RuntimeFailure.notFound("sandbox \(record.sandboxID)")
        }

        // Boot the VM on first use, with every container added so far already
        // registered. Virtualization.framework has no hotplug, so anything
        // added after this point cannot join the pod.
        if !sandbox.booted {
            try await sandbox.pod.create()
            sandboxes[record.sandboxID]?.booted = true
        }

        try await sandbox.pod.startContainer(id)
        containers[id]?.state = .running
        containers[id]?.startedAt = Self.now()

        // Reap asynchronously so the exit code is available to ContainerStatus
        // without the kubelet having to ask the pod directly.
        let pod = sandbox.pod
        Task { [weak self] in
            let status = try? await pod.waitContainer(id)
            await self?.recordExit(id, code: status?.exitCode ?? -1)
        }
    }

    private func recordExit(_ id: String, code: Int32) {
        guard containers[id] != nil else { return }
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

    func container(_ id: String) throws -> ContainerRecord {
        guard let record = containers[id] else { throw RuntimeFailure.notFound("container \(id)") }
        return record
    }

    func listContainers() -> [ContainerRecord] { Array(containers.values) }

    // MARK: - Images

    func pullImage(_ reference: String) async throws -> String {
        let platform = ContainerizationOCI.Platform(arch: "arm64", os: "linux", variant: "v8")
        let image = try await store.pull(reference: reference, platform: platform)

        if rootfsCache[reference] == nil {
            let safe = reference.replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
            let path = config.stateDir.appending(component: "image-\(safe).ext4")
            let mount: Containerization.Mount
            do {
                mount = try await EXT4Unpacker(capacityInBytes: 2.gib())
                    .unpack(image, for: platform, at: path)
            } catch let error as ContainerizationError where error.code == .exists {
                mount = .block(format: "ext4", source: path.path(), destination: "/", options: [])
            }
            rootfsCache[reference] = mount
            if !image.digest.isEmpty { rootfsCache[image.digest] = mount }
        }

        // The kubelet rejects an image whose id or size is unset -- it reports
        // ImageInspectError and the pod never starts. Size is taken from the
        // unpacked root filesystem, which is the thing that actually occupies
        // disk in this runtime.
        let digest = image.digest.isEmpty ? reference : image.digest
        var size: UInt64 = 0
        if let mount = rootfsCache[reference],
           let attrs = try? FileManager.default.attributesOfItem(atPath: mount.source),
           let bytes = attrs[.size] as? UInt64 {
            size = bytes
        }

        var entry = Runtime_V1_Image()
        entry.id = digest
        entry.repoTags = [reference]
        entry.repoDigests = image.digest.isEmpty ? [] : ["\(reference)@\(image.digest)"]
        entry.size = max(size, 1)
        pulledImages[reference] = entry
        if !image.digest.isEmpty { pulledImages[image.digest] = entry }
        return digest
    }

    func imageStatus(_ reference: String) -> Runtime_V1_Image? { pulledImages[reference] }
    func listImages() -> [Runtime_V1_Image] { Array(pulledImages.values) }

    func removeImage(_ reference: String) {
        pulledImages.removeValue(forKey: reference)
        rootfsCache.removeValue(forKey: reference)
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

    func stateDirPath() -> String { config.stateDir.path() }

    func stateDirUsage() -> (capacity: UInt64, used: UInt64, inodes: UInt64) {
        var st = statfs()
        guard statfs(config.stateDir.path(), &st) == 0 else { return (0, 0, 0) }
        let block = UInt64(st.f_bsize)
        return (UInt64(st.f_blocks) * block, UInt64(st.f_blocks - st.f_bfree) * block, UInt64(st.f_files))
    }
}
