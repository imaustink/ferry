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
        /// This node's address, reported as a macOS pod's sandbox IP. The guest
        /// is NAT'd behind the host with no routable address of its own, so its
        /// network identity is the host's (as a host-network pod's is) -- and a
        /// sandbox must report *some* IP or the kubelet takes it for broken and
        /// kills it. Real pod-network addressing is future work (design doc).
        var nodeIP: String
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
        /// Where the container's root was assembled in the guest (OS base + the
        /// image layer); an exec chroots into it. Set once the container starts.
        var rootPath: String?
        /// The detached task streaming the entrypoint's output until it exits.
        /// Held so it is not dropped mid-run and can be cancelled on stop.
        var runTask: Task<Void, Never>?
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
            // The node's own address: the guest is NAT'd behind the host with no
            // routable address of its own, so it shares the host's identity (as a
            // host-network pod does). A sandbox must report an IP or the kubelet
            // takes it for broken and kills it -- which is why a long-running
            // macOS pod was torn down seconds in. Real pod networking is future
            // work (docs/design/macos-cri-sandbox.md).
            ip: config.nodeIP, createdAt: Self.now(), ready: true)
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

    /// Boot the sandbox if needed, assemble the container's root in the guest
    /// (the baked OS base plus the image layer), then run the entrypoint chrooted
    /// into it, streaming output to the container log and recording its exit.
    /// Returns once the container has started; the run continues in the
    /// background, the way the Linux path reaps a container asynchronously.
    func startContainer(_ id: String) async throws {
        guard let c = containers[id] else { throw DarwinRuntimeError.notFound("no darwin container \(id)") }
        guard let s = sandboxes[c.info.sandboxID] else {
            throw DarwinRuntimeError.notFound("darwin container \(id) has no sandbox")
        }
        if !s.booted {
            try await s.sandbox.boot()
            s.booted = true
        }

        // Fetch the image host-side and assemble the container root in the guest.
        // The kubelet rewrites config.image.image to the id ImageStatus returned
        // (a digest), so fetch by the reference as written in the pod spec, which
        // CRI carries in user_specified_image.
        let ref = c.config.image.userSpecifiedImage.isEmpty
            ? c.config.image.image : c.config.image.userSpecifiedImage
        let image = try await DarwinImageStore.fetch(ref)
        let root = "/private/var/ferry/pods/\(id)/root"
        try await assembleRoot(root, image: image, in: s.sandbox)

        let logFile = c.info.logPath.isEmpty ? nil : try? ContainerLogFile(path: c.info.logPath)
        c.log = logFile
        c.rootPath = root
        c.info = c.info.started(at: Self.now())

        let argv = DarwinImageStore.resolvedCommand(image: image, command: c.config.command, args: c.config.args)
        var env: [String: String] = [:]
        for e in image.env {
            let (k, v) = Self.splitEnv(e); if !k.isEmpty { env[k] = v }
        }
        for kv in c.config.envs { env[kv.key] = kv.value }
        let workdir = c.config.workingDir.isEmpty ? image.workingDir : c.config.workingDir
        // chroot into the image root and run the entrypoint. macOS chroot(8) has
        // no chdir flag, and the agent's cwd would apply on the real FS before the
        // chroot, so WORKDIR is entered inside the new root by a thin shell:
        // `cd <workdir>; exec <argv>`. The env carries the merged image and
        // container environment.
        var runArgv = ["/usr/sbin/chroot", root]
        if workdir.isEmpty {
            runArgv += argv
        } else {
            runArgv += ["/bin/sh", "-c", "cd \"$0\" 2>/dev/null; exec \"$@\"", workdir] + argv
        }
        let req = DarwinRunRequest(argv: runArgv, env: env.isEmpty ? nil : env, cwd: nil, chroot: nil)

        // Stream the entrypoint's output in a detached task and return now, with
        // the container reported "running" (set above): StartContainer must not
        // block for the life of the process, or a long-running container would
        // hang the kubelet and this actor would be frozen for every other pod.
        // The task is held on the record so it is not dropped mid-run, streams
        // each frame to a per-stream writer -- which splits output into the
        // one-line-per-record shape the CRI log format needs (a single append
        // would prefix only the first line and `kubectl logs` would show only
        // that) -- and records the exit status when the process ends.
        let sandbox = s.sandbox
        containers[id]?.runTask = Task { [weak self] in
            let outW = logFile.map { ContainerLogWriter(file: $0, stream: .stdout) }
            let errW = logFile.map { ContainerLogWriter(file: $0, stream: .stderr) }
            let exit: Int32
            do {
                exit = try await sandbox.run(req) { kind, payload in
                    switch kind {
                    case .stdout: try? outW?.write(Data(payload))
                    case .stderr, .error: try? errW?.write(Data(payload))
                    case .exit: break
                    }
                }
            } catch {
                FileHandle.standardError.write("darwin \(id): run threw \(error)\n".data(using: .utf8)!)
                exit = -1
            }
            try? outW?.close()
            try? errW?.close()
            await self?.finishContainer(id, exit: exit)
        }
    }

    /// Builds the container root in the guest: the baked OS base (dyld + the
    /// shared cache + /bin etc., from `ferry-darwin -prepare` at bake time)
    /// cloned in, then the image layer unpacked over it -- so a `FROM macos`
    /// image, which ships only the workload's own files, has an OS to link
    /// against. The command later runs `chroot`ed here.
    private func assembleRoot(_ root: String, image: DarwinImage, in sandbox: DarwinSandbox) async throws {
        let osBase = "/private/var/ferry/darwin/os"
        let assemble = """
        set -e
        R="$0"
        rm -rf "$R"; mkdir -p "$R"
        if [ -d "\(osBase)" ]; then
            cp -cR "\(osBase)/." "$R/" 2>/dev/null || cp -R "\(osBase)/." "$R/"
        fi
        mkdir -p "$R/dev" "$R/tmp" "$R/private/tmp" "$R/var/tmp"
        """
        let (ac, _, ae) = try await sandbox.exec(DarwinRunRequest(argv: ["/bin/sh", "-c", assemble, root]))
        guard ac == 0 else {
            throw DarwinRuntimeError.invalid("assembling the container root: \(Self.text(ae))")
        }
        let b64 = "\(root).layer.b64"
        try await sandbox.uploadBase64(image.layer, toGuestPath: b64)
        // BSD tar auto-detects gzip, so the layer is unpacked as served.
        let untar = "set -e; base64 -D < \"$1\" | tar xf - -C \"$0\"; rm -f \"$1\""
        let (tc, _, te) = try await sandbox.exec(DarwinRunRequest(argv: ["/bin/sh", "-c", untar, root, b64]))
        guard tc == 0 else {
            throw DarwinRuntimeError.invalid("unpacking the image layer: \(Self.text(te))")
        }
    }

    /// A probe (ExecSync): run a command chrooted into the container's root and
    /// collect its output and exit status. This is what liveness and readiness
    /// exec probes use.
    func execSync(_ id: String, cmd: [String]) async throws -> (stdout: Data, stderr: Data, exit: Int32) {
        guard let c = containers[id] else { throw DarwinRuntimeError.notFound("no darwin container \(id)") }
        guard let root = c.rootPath, let s = sandboxes[c.info.sandboxID], s.booted else {
            throw DarwinRuntimeError.invalid("darwin container \(id) is not running")
        }
        let (code, out, err) = try await s.sandbox.exec(DarwinRunRequest(argv: cmd, chroot: root))
        return (out, err, code)
    }

    /// A streamed exec (`kubectl exec -- cmd`): run a command chrooted into the
    /// container's root, streaming its output to `onOutput` as it arrives, and
    /// return the exit status. Stdin and a TTY are not wired -- the guest agent
    /// runs argv with stdin from /dev/null -- so an interactive `exec -it` runs
    /// the command but sees no input (docs/design/macos-cri-sandbox.md).
    func execStream(_ id: String, cmd: [String],
                    onOutput: @escaping @Sendable (DarwinFrameKind, [UInt8]) -> Void) async throws -> Int32 {
        guard let c = containers[id] else { throw DarwinRuntimeError.notFound("no darwin container \(id)") }
        guard let root = c.rootPath, let s = sandboxes[c.info.sandboxID], s.booted else {
            throw DarwinRuntimeError.invalid("darwin container \(id) is not running")
        }
        return try await s.sandbox.run(DarwinRunRequest(argv: cmd, chroot: root), onOutput: onOutput)
    }

    /// Measured resource use for a running darwin container. A VM-per-pod pod is
    /// the whole guest, so these are the guest's totals: resident memory (the sum
    /// of process RSS) and cumulative CPU time, which metrics-server turns into a
    /// rate. There are no cgroups, so it is measured with `ps` in the guest.
    struct Stats: Sendable {
        var memoryBytes: UInt64
        var cpuNanoseconds: UInt64
    }

    func stats(_ id: String) async -> Stats? {
        guard let c = containers[id], c.info.state == .running,
              let s = sandboxes[c.info.sandboxID], s.booted else { return nil }
        // rss in KiB summed to bytes; cumulative CPU time ([HH:]MM:SS.ss) summed
        // to seconds. Runs against the whole guest -- the pod is the VM.
        let script = "rss=$(ps -A -o rss= | awk '{s+=$1} END{print s*1024}'); "
            + "cpu=$(ps -A -o time= | awk -F: '{n=NF; sec=$n; if(n>=2) sec+=$(n-1)*60; if(n>=3) sec+=$(n-2)*3600; t+=sec} END{print t}'); "
            + "printf '%s %s' \"$rss\" \"$cpu\""
        guard let r = try? await s.sandbox.exec(DarwinRunRequest(argv: ["/bin/sh", "-c", script])), r.exit == 0,
              let text = String(data: r.stdout, encoding: .utf8) else { return nil }
        let parts = text.split(separator: " ")
        guard parts.count == 2, let mem = UInt64(parts[0]), let cpuSec = Double(parts[1]) else { return nil }
        return Stats(memoryBytes: mem, cpuNanoseconds: UInt64(cpuSec * 1_000_000_000))
    }

    /// The ids of running darwin containers, for a stats listing.
    func runningContainerIDs() -> [String] {
        containers.values.filter { $0.info.state == .running }.map(\.info.id)
    }

    /// Records a container's exit; called from the background run task. Only a
    /// still-running container is updated: a stop already set the exit code, and
    /// the guest teardown that follows makes the run throw -- that late failure
    /// must not clobber the stop's status.
    private func finishContainer(_ id: String, exit: Int32) {
        guard let c = containers[id], c.info.state == .running else { return }
        c.info = c.info.exited(code: exit, reason: exit == 0 ? "Completed" : "Error", at: Self.now())
        c.runTask = nil
    }

    private static func splitEnv(_ s: String) -> (String, String) {
        guard let i = s.firstIndex(of: "=") else { return (s, "") }
        return (String(s[..<i]), String(s[s.index(after: i)...]))
    }

    private static func text(_ d: Data) -> String {
        String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func stopContainer(_ id: String, timeout: Int64) async throws {
        guard let c = containers[id] else { return }
        // Stopping a VM-per-pod container is stopping its guest; the sandbox stop
        // does that. Mark it exited so the kubelet sees it end, and cancel the
        // run task so it does not linger once the guest goes away.
        c.runTask?.cancel()
        c.runTask = nil
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
