// The darwin side of the CRI, kept entirely apart from the Linux PodRuntime.
//
// A macOS pod is a VM sandbox on the host (docs/design/macos-cri-sandbox.md).
// Rather than teach PodRuntime's LinuxPod-shaped SandboxRecord to be two OSes at
// once -- which would thread darwin branches through every Linux code path and
// risk the working Linux runtime -- darwin sandboxes live here, in their own
// actor, and FerryRuntimeService routes an id to whichever side owns it. Nothing
// in PodRuntime changes.
//
// This owns the CRI lifecycle for darwin: create a sandbox record, boot the
// DarwinSandbox lazily on the first StartContainer, run the container's command
// in the guest over the agent (streaming its output to the container log), report
// status and exit, and tear the guest down. It reports through small Sendable
// info structs that FerryRuntimeService turns into CRI protos, the same fields it
// reads off a SandboxRecord for a Linux pod.
//
// Two things are deliberately not finished here, both called out in the design
// doc and both needing a real Mac to develop against: assembling the container
// root from the image layers plus the guest's baked OS base (the `chroot` a
// `FROM macos` image needs -- today the command runs against the guest's own
// filesystem), and exec/stats parity. What is here is the sandbox and container
// lifecycle, compiled and driving the DarwinSandbox backend.

import Foundation

/// The OS-agnostic sandbox facts FerryRuntimeService needs to build a
/// PodSandboxStatus / PodSandbox proto -- the same fields it reads off a Linux
/// SandboxRecord.
struct DarwinSandboxInfo: Sendable {
    let id: String
    let name: String
    let uid: String
    let namespace: String
    let attempt: UInt32
    let labels: [String: String]
    let annotations: [String: String]
    let ip: String
    let createdAt: Int64
    let ready: Bool
}

/// A darwin container's run state, matching the CRI's created/running/exited.
enum DarwinContainerState: Sendable {
    case created
    case running
    case exited
}

/// The OS-agnostic container facts for a ContainerStatus / Container proto.
struct DarwinContainerInfo: Sendable {
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
    let startedAt: Int64
    let finishedAt: Int64
    let exitCode: Int32
    let state: DarwinContainerState
    let reason: String
}

enum DarwinRuntimeError: Error, CustomStringConvertible {
    case unavailable(String)
    case notFound(String)
    case invalid(String)

    var description: String {
        switch self {
        case .unavailable(let m): return m
        case .notFound(let m): return m
        case .invalid(let m): return m
        }
    }
}

actor DarwinRuntime {
    struct Config: Sendable {
        /// The golden macOS bundle every sandbox is cloned from. Nil when this
        /// Mac has none, which makes darwin pods unavailable (they stay Pending,
        /// as they would with no macOS node).
        var golden: String?
        var stateDir: URL
        var defaultCPUs: Int
        var defaultMemoryBytes: UInt64
        /// Apple's two-VM-per-Mac ceiling, re-homed from Karpenter. A third
        /// concurrent macOS sandbox is refused.
        var maxGuests: Int
    }

    private let config: Config

    private final class Sandbox {
        let info: DarwinSandboxInfo
        let sandbox: DarwinSandbox
        let logDirectory: String
        var containers: [String] = []
        var booted = false
        init(info: DarwinSandboxInfo, sandbox: DarwinSandbox, logDirectory: String) {
            self.info = info
            self.sandbox = sandbox
            self.logDirectory = logDirectory
        }
    }

    private final class Container {
        var info: DarwinContainerInfo
        let config: Runtime_V1_ContainerConfig
        var log: ContainerLogFile?
        init(info: DarwinContainerInfo, config: Runtime_V1_ContainerConfig) {
            self.info = info
            self.config = config
        }
    }

    private var sandboxes: [String: Sandbox] = [:]
    private var containers: [String: Container] = [:]
    private var counter: UInt64 = 0

    init(config: Config) {
        self.config = config
    }

    /// Whether darwin pods can run here at all: only with a golden image.
    var available: Bool { config.golden != nil }

    private func nextID(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)-\(String(format: "%016x", counter))-\(UUID().uuidString.prefix(8))"
    }

    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000_000_000) }

    // MARK: sandbox membership (how the service routes an id)

    func hasSandbox(_ id: String) -> Bool { sandboxes[id] != nil }
    func hasContainer(_ id: String) -> Bool { containers[id] != nil }

    // MARK: sandbox lifecycle

    func runPodSandbox(config cfg: Runtime_V1_PodSandboxConfig) throws -> String {
        guard let golden = self.config.golden else {
            throw DarwinRuntimeError.unavailable(
                "this Mac has no macOS golden image, so a ferry-macos-vm pod cannot run -- "
                    + "`ferry mac-image bake` (see docs/RUNTIMES.md#building-the-image)")
        }
        let live = sandboxes.values.filter { $0.booted }.count
        if live >= config.maxGuests {
            throw DarwinRuntimeError.unavailable(
                "the Mac already runs \(config.maxGuests) macOS guests (Apple's licence ceiling); "
                    + "a third macOS pod waits until one frees")
        }
        let id = nextID("darwin-sandbox")
        let workDir = config.stateDir.appendingPathComponent("darwin").appendingPathComponent(id)
        let sandbox = DarwinSandbox(
            id: id, golden: URL(filePath: golden), workDir: workDir,
            cpus: config.defaultCPUs, memoryBytes: config.defaultMemoryBytes)
        let info = DarwinSandboxInfo(
            id: id, name: cfg.metadata.name, uid: cfg.metadata.uid,
            namespace: cfg.metadata.namespace, attempt: cfg.metadata.attempt,
            labels: cfg.labels, annotations: cfg.annotations,
            // No pod-network address yet (NAT only); reported empty, as a
            // sandbox with host networking would be.
            ip: "", createdAt: Self.now(), ready: true)
        sandboxes[id] = Sandbox(info: info, sandbox: sandbox, logDirectory: cfg.logDirectory)
        return id
    }

    func sandboxStatus(_ id: String) throws -> DarwinSandboxInfo {
        guard let s = sandboxes[id] else { throw DarwinRuntimeError.notFound("no darwin sandbox \(id)") }
        return s.info
    }

    func listSandboxes() -> [DarwinSandboxInfo] { sandboxes.values.map(\.info) }

    func stopPodSandbox(_ id: String) async throws {
        guard let s = sandboxes[id] else { return }
        for cid in s.containers {
            if let c = containers[cid], c.info.state == .running {
                containers[cid]?.info = c.info.exited(code: 137, reason: "SandboxStopped", at: Self.now())
            }
        }
        if s.booted {
            await s.sandbox.shutdown()
            s.booted = false
        }
    }

    func removePodSandbox(_ id: String) async throws {
        guard let s = sandboxes[id] else { return }
        if s.booted { await s.sandbox.shutdown() }
        for cid in s.containers { containers.removeValue(forKey: cid) }
        sandboxes.removeValue(forKey: id)
    }

    // MARK: container lifecycle

    func createContainer(sandboxID: String, config cfg: Runtime_V1_ContainerConfig) throws -> String {
        guard let s = sandboxes[sandboxID] else {
            throw DarwinRuntimeError.notFound("no darwin sandbox \(sandboxID)")
        }
        let id = nextID("darwin-container")
        let info = DarwinContainerInfo(
            id: id, sandboxID: sandboxID, name: cfg.metadata.name, attempt: cfg.metadata.attempt,
            image: cfg.image.image, imageRef: cfg.image.image,
            labels: cfg.labels, annotations: cfg.annotations,
            logPath: cfg.logPath.isEmpty ? "" : "\(s.logDirectory)/\(cfg.logPath)",
            createdAt: Self.now(), startedAt: 0, finishedAt: 0, exitCode: 0,
            state: .created, reason: "")
        containers[id] = Container(info: info, config: cfg)
        sandboxes[sandboxID]?.containers.append(id)
        return id
    }

    func containerStatus(_ id: String) throws -> DarwinContainerInfo {
        guard let c = containers[id] else { throw DarwinRuntimeError.notFound("no darwin container \(id)") }
        return c.info
    }

    func listContainers() -> [DarwinContainerInfo] { containers.values.map(\.info) }

    /// Boot the sandbox if needed, then run the container's command in the guest,
    /// streaming its output to the container log and recording its exit. Returns
    /// once the container has started (the run continues in the background), the
    /// way the Linux path starts a container and reaps it asynchronously.
    func startContainer(_ id: String) async throws {
        guard let c = containers[id] else { throw DarwinRuntimeError.notFound("no darwin container \(id)") }
        guard let s = sandboxes[c.info.sandboxID] else {
            throw DarwinRuntimeError.notFound("darwin container \(id) has no sandbox")
        }
        if !s.booted {
            try await s.sandbox.boot()
            s.booted = true
        }

        let logFile = c.info.logPath.isEmpty ? nil : try? ContainerLogFile(path: c.info.logPath)
        c.log = logFile
        c.info = c.info.started(at: Self.now())

        let req = Self.runRequest(for: c.config)
        let sandbox = s.sandbox
        // The run outlives this call: stream frames into the log, and record the
        // exit back on the actor when the process ends.
        Task { [weak self] in
            let exit: Int32
            do {
                exit = try await sandbox.run(req) { kind, payload in
                    guard let logFile else { return }
                    switch kind {
                    case .stdout: logFile.append(Data(payload), stream: .stdout, tag: "F")
                    case .stderr, .error: logFile.append(Data(payload), stream: .stderr, tag: "F")
                    case .exit: break
                    }
                }
            } catch {
                exit = -1
            }
            await self?.finishContainer(id, exit: exit)
        }
    }

    /// Records a container's exit; called from the background run task.
    private func finishContainer(_ id: String, exit: Int32) {
        guard let c = containers[id] else { return }
        c.info = c.info.exited(code: exit, reason: exit == 0 ? "Completed" : "Error", at: Self.now())
    }

    func stopContainer(_ id: String, timeout: Int64) async throws {
        guard let c = containers[id] else { return }
        // Stopping a VM-per-pod container is stopping its guest; the sandbox stop
        // does that. Mark it exited so the kubelet sees it end.
        if c.info.state == .running {
            containers[id]?.info = c.info.exited(code: 137, reason: "Stopped", at: Self.now())
        }
        if let s = sandboxes[c.info.sandboxID], s.booted {
            await s.sandbox.shutdown()
            s.booted = false
        }
    }

    func removeContainer(_ id: String) throws {
        guard let c = containers[id] else { return }
        sandboxes[c.info.sandboxID]?.containers.removeAll { $0 == id }
        containers.removeValue(forKey: id)
    }

    /// Builds the guest exec request from a CRI container config. The command is
    /// the image's entrypoint/cmd as the kubelet resolved it (command + args),
    /// with the container's environment and working directory.
    ///
    /// NB: no `chroot` yet -- assembling the image's files plus the guest OS base
    /// into a root is the remaining guest-side step (design doc). Until then the
    /// command runs against the guest's own filesystem.
    private static func runRequest(for cfg: Runtime_V1_ContainerConfig) -> DarwinRunRequest {
        var argv = cfg.command + cfg.args
        if argv.isEmpty { argv = ["/usr/bin/true"] }
        var env: [String: String] = [:]
        for kv in cfg.envs { env[kv.key] = kv.value }
        let cwd = cfg.workingDir.isEmpty ? nil : cfg.workingDir
        return DarwinRunRequest(argv: argv, env: env.isEmpty ? nil : env, cwd: cwd)
    }
}

// MARK: - info transitions

private extension DarwinContainerInfo {
    func started(at t: Int64) -> DarwinContainerInfo {
        DarwinContainerInfo(
            id: id, sandboxID: sandboxID, name: name, attempt: attempt, image: image, imageRef: imageRef,
            labels: labels, annotations: annotations, logPath: logPath, createdAt: createdAt,
            startedAt: t, finishedAt: 0, exitCode: 0, state: .running, reason: "")
    }

    func exited(code: Int32, reason: String, at t: Int64) -> DarwinContainerInfo {
        DarwinContainerInfo(
            id: id, sandboxID: sandboxID, name: name, attempt: attempt, image: image, imageRef: imageRef,
            labels: labels, annotations: annotations, logPath: logPath, createdAt: createdAt,
            startedAt: startedAt == 0 ? t : startedAt, finishedAt: t, exitCode: code, state: .exited, reason: reason)
    }
}
