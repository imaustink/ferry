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
        let ip = "\(interface.ipv4Address)".split(separator: "/").first.map(String.init) ?? ""

        // Kubernetes sends resource limits per container, not per sandbox, so
        // the VM is sized from defaults here and containers are bounded inside
        // it by cgroups. Right-sizing the VM from the pod's aggregate requests
        // is a worthwhile refinement, not a correctness issue.
        let pod = try makePod(id: id, interface: interface, cfg: cfg)
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
            usesReservedAddress: wantsReserved && dnsInterfaceInUse,
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

    private func makePod(id: String, interface: any Interface, cfg: Runtime_V1_PodSandboxConfig) throws -> LinuxPod {
        try LinuxPod(id, vmm: VZVirtualMachineManager(kernel: kernel, initialFilesystem: initfs)) { c in
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
    func sandboxAddress(_ id: String) -> String? { sandboxes[id]?.ip }

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
        let imageConfig = imageConfigs[imageRef]
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
            image: imageRef, imageRef: imageRef,
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
        stderr: any Writer
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

        if let imageConfig = try? await image.config(for: platform).config {
            imageConfigs[reference] = imageConfig
            if !image.digest.isEmpty { imageConfigs[image.digest] = imageConfig }
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
