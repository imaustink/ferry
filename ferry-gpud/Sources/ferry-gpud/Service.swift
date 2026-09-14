// The service: what the sockets serve, and which sockets exist.
//
// There are two kinds. The control socket is ferry-cri's, and mints a socket
// for a pod that asked for a GPU. A pod socket is that pod's, and is the only
// thing the pod ever sees -- it carries no pod identifier, because it does not
// need one: there is exactly one pod that socket could have come from, which is
// the whole argument for the relay over a listener on the pod network
// (docs/GPU.md).

import Foundation

struct PodRegistration: Codable, Sendable {
    var uid: String
    var namespace: String?
    var name: String?
    /// When the socket was bound, ISO8601. Carried so something that knows what
    /// pods actually exist can tell a grant that has outlived its pod from one
    /// made a moment ago for a pod it has not seen yet.
    var grantedAt: String?
    /// From the pod's PriorityClass. Persisted with the grant so a restarted
    /// daemon does not quietly demote every pod to ordinary.
    var priority: Int32?
}

struct PodEntry: Encodable {
    var uid: String
    var namespace: String?
    var name: String?
    var socket: String
    var grantedAt: String?
    var priority: Int32
    var usage: PodUsage
}

struct Capacity: Encodable {
    var limit: Int
    var granted: Int
    /// Requests queued or running right now. The number that says whether
    /// `limit` is set too high for what these pods actually do.
    var pending: Int
    /// The same, split by lane. "Something is queued" is much less useful than
    /// "the GPU is backed up and the model is idle".
    var pendingByLane: [String: Int]
}

enum ServiceError: Error, CustomStringConvertible {
    case full(Int)
    case badRequest(String)

    var description: String {
        switch self {
        case .full(let limit): "the node's GPU capacity is \(limit) and all of it is granted"
        case .badRequest(let m): m
        }
    }
}

/// Holds the GPU, the model, the scheduler, and the set of pods currently
/// granted a socket.
final class Service: @unchecked Sendable {
    private let gpu: GPU
    private let generator = Generator()
    private let lanes: GPULanes
    private let socketDirectory: String
    /// How many pods may hold a relay at once. There is one GPU; this is a
    /// policy number, not a discovered one, and it is what the node advertises
    /// as ferry.dev/gpu.
    private let limit: Int
    /// The longest any single request may take, queue time included.
    private let requestTimeout: TimeInterval

    private let lock = NSLock()
    private var pods: [String: (registration: PodRegistration, server: UnixHTTPServer)] = [:]

    init(gpu: GPU, lanes: GPULanes, socketDirectory: String,
         limit: Int, requestTimeout: TimeInterval) {
        self.gpu = gpu
        self.lanes = lanes
        self.socketDirectory = socketDirectory
        self.limit = limit
        self.requestTimeout = requestTimeout
    }

    // MARK: - Pods

    func socketPath(uid: String) -> String { "\(socketDirectory)/\(uid).sock" }

    /// Where the set of granted pods is kept, so a daemon restart does not
    /// silently break every pod holding a socket.
    private var stateFile: String { "\(socketDirectory)/grants.json" }

    /// Binds a socket for a pod. Idempotent: the kubelet retries, and a retry
    /// must not cost a second slot or a second listener on the same path.
    func grant(_ registration: PodRegistration) throws -> PodEntry {
        guard !registration.uid.isEmpty else { throw ServiceError.badRequest("uid is required") }
        // The uid becomes a filename, so it may not wander out of the directory.
        guard !registration.uid.contains("/"), !registration.uid.contains(".."),
              registration.uid.count <= 64 else {
            throw ServiceError.badRequest("uid is not a plausible pod uid")
        }

        let entry = try lock.withLock {
            if let existing = pods[registration.uid] {
                return self.entry(uid: registration.uid, registration: existing.registration)
            }
            guard pods.count < limit else { throw ServiceError.full(limit) }
            var registration = registration
            registration.grantedAt = ISO8601DateFormatter().string(from: Date())
            try bind(registration)
            log("granted \(describe(registration)) -> \(socketPath(uid: registration.uid))")
            return self.entry(uid: registration.uid, registration: registration)
        }
        persist()
        return entry
    }

    /// Called with the lock held. Binds the socket and tells the scheduler what
    /// this pod is worth, before it can ask for anything.
    private func bind(_ registration: PodRegistration) throws {
        lanes.setPriority(registration.priority ?? 0, for: registration.uid)
        let path = socketPath(uid: registration.uid)
        let server = UnixHTTPServer(path: path, identity: registration.uid) { [weak self] request, identity in
            self?.handlePod(request, identity: identity) ?? .error("shutting down", status: 503)
        }
        try server.start()
        pods[registration.uid] = (registration, server)
    }

    func revoke(uid: String) -> Bool {
        let removed = lock.withLock { () -> Bool in
            guard let held = pods.removeValue(forKey: uid) else { return false }
            held.server.stop()
            log("revoked \(describe(held.registration))")
            return true
        }
        guard removed else { return false }
        // Anything this pod had queued or running goes with it. The container is
        // gone; finishing its matmul would only make the next pod wait.
        let stopped = lanes.cancel(pod: uid)
        if stopped > 0 { log("cancelled \(stopped) in-flight request(s) for \(uid)") }
        lanes.forget(pod: uid)
        persist()
        return true
    }

    /// Releases every socket. `forget` says whether the pods should also be
    /// dropped from the state file.
    ///
    /// Shutting down does *not* forget them: a restart -- a crash, or a
    /// supervisor bouncing the daemon -- should put the sockets back, and
    /// rewriting an empty state file on the way out is exactly how that would
    /// be lost. `ferry up` deletes the file instead, because that is the case
    /// where the pods really are gone.
    func revokeAll(forget: Bool = true) {
        let held = lock.withLock { () -> [String] in
            let uids = Array(pods.keys)
            for (_, entry) in pods { entry.server.stop() }
            pods.removeAll()
            return uids
        }
        for uid in held { lanes.cancel(pod: uid) }
        if forget { persist() }
    }

    /// Re-binds the sockets a previous instance had granted.
    ///
    /// The relay dials the host socket when the guest connects, so a pod whose
    /// socket reappears at the same path simply works again. Without this, a
    /// restarted daemon leaves every pod holding a path that nothing answers,
    /// and nothing in the pod or the cluster says why.
    func restore() {
        guard let data = FileManager.default.contents(atPath: stateFile),
              let saved = try? JSONDecoder().decode([PodRegistration].self, from: data),
              !saved.isEmpty
        else { return }

        var restored = 0
        lock.withLock {
            for registration in saved.prefix(limit) {
                do {
                    try bind(registration)
                    restored += 1
                } catch {
                    log("could not restore \(describe(registration)): \(error)")
                }
            }
        }
        if restored > 0 { log("restored \(restored) pod socket(s) from \(stateFile)") }
        persist()
    }

    private func persist() {
        let saved = lock.withLock { pods.values.map(\.registration) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(saved) else { return }
        try? data.write(to: URL(filePath: stateFile), options: .atomic)
        chmod(stateFile, 0o600)
    }

    var listing: [PodEntry] {
        lock.withLock {
            pods.map { entry(uid: $0.key, registration: $0.value.registration) }
                .sorted { $0.uid < $1.uid }
        }
    }

    var capacity: Capacity {
        let granted = lock.withLock { pods.count }
        return Capacity(limit: limit, granted: granted, pending: lanes.pending,
                        pendingByLane: lanes.pendingByLane)
    }

    /// Called with the lock held.
    private func entry(uid: String, registration: PodRegistration) -> PodEntry {
        PodEntry(uid: uid, namespace: registration.namespace, name: registration.name,
                 socket: socketPath(uid: uid), grantedAt: registration.grantedAt,
                 priority: registration.priority ?? 0, usage: lanes.ledger.usage(for: uid))
    }

    private func describe(_ registration: PodRegistration) -> String {
        if let namespace = registration.namespace, let name = registration.name {
            return "\(namespace)/\(name) (\(registration.uid))"
        }
        return registration.uid
    }

    func drain(timeout: TimeInterval) {
        lanes.drain(timeout: timeout)
        revokeAll(forget: false)
    }

    // MARK: - Routing

    /// The control socket. ferry-cri's, never a pod's.
    func handleControl(_ request: HTTPRequest, identity: String?) -> HTTPResponse {
        switch (request.method, request.segments) {
        case ("GET", ["healthz"]):
            return .json(["status": "ok"])

        case ("GET", ["capacity"]):
            return .json(capacity)

        case ("GET", ["pods"]):
            return .json(listing)

        case ("GET", ["stats"]):
            return .json(lanes.ledger.all)

        case ("GET", ["metrics"]):
            return metrics()

        case ("POST", ["pods"]):
            do {
                let registration = try request.json(PodRegistration.self)
                return .json(try grant(registration), status: 201)
            } catch let error as ServiceError {
                if case .full = error { return .error("\(error)", status: 409) }
                return .error("\(error)", status: 400)
            } catch {
                return .error("\(error)", status: 400)
            }

        case ("DELETE", let segments) where segments.count == 2 && segments[0] == "pods":
            return revoke(uid: segments[1])
                ? .json(["revoked": segments[1]])
                : .error("no pod \(segments[1])", status: 404)

        // The read-only device endpoints are served here too, so `ferry status`
        // can ask what the GPU is without holding a pod socket.
        case ("GET", ["v1", "device"]), ("GET", ["v1", "model"]):
            return handlePod(request, identity: nil)

        default:
            return .error("no route for \(request.method) \(request.path)", status: 404)
        }
    }

    /// A pod socket. `identity` is the pod uid, supplied by the listener rather
    /// than by the caller -- a pod cannot claim to be another pod.
    func handlePod(_ request: HTTPRequest, identity: String?) -> HTTPResponse {
        // "control" only ever reaches here from the two read-only routes above.
        let pod = identity ?? "control"

        switch (request.method, request.segments) {
        case ("GET", ["healthz"]):
            return .json(["status": "ok"])

        case ("GET", ["v1", "device"]):
            return .json(gpu.info)

        case ("GET", ["v1", "model"]):
            return .json(generator.status)

        case ("GET", ["v1", "usage"]):
            // A pod may see its own accounting and nobody else's.
            return .json(lanes.ledger.usage(for: pod))

        case ("POST", ["v1", "matmul"]):
            struct Body: Decodable { var size: Int?; var iterations: Int? }
            let body = (try? request.json(Body.self)) ?? Body(size: nil, iterations: nil)
            let size = body.size ?? 1024
            let iterations = body.iterations ?? 10
            return run(pod: pod, lane: .compute,
                       what: "matmul \(size)x\(size) x\(iterations)") { job in
                try self.gpu.matmul(size: size, iterations: iterations, job: job)
            }

        case ("POST", ["v1", "generate"]):
            guard let body = try? request.json(GenerateRequest.self) else {
                return .error("expected {\"prompt\": \"...\"}", status: 400)
            }
            return run(pod: pod, lane: .model,
                       what: "generate \(body.prompt.count) chars") { job in
                try self.generator.generate(body, job: job)
            }

        default:
            return .error("no route for \(request.method) \(request.path)", status: 404)
        }
    }

    /// The same numbers as /stats, in the format anything that scrapes metrics
    /// already understands. Nothing in ferry scrapes it -- this is here so that
    /// what the GPU is doing is not knowledge trapped inside one daemon.
    private func metrics() -> HTTPResponse {
        var lines = [
            "# HELP ferry_gpu_capacity Pods that may hold the GPU at once.",
            "# TYPE ferry_gpu_capacity gauge",
            "ferry_gpu_capacity \(capacity.limit)",
            "# HELP ferry_gpu_granted Pods holding a GPU socket.",
            "# TYPE ferry_gpu_granted gauge",
            "ferry_gpu_granted \(capacity.granted)",
            "# HELP ferry_gpu_pending Requests queued or running.",
            "# TYPE ferry_gpu_pending gauge",
            "ferry_gpu_pending \(capacity.pending)",
        ]
        for (lane, pending) in capacity.pendingByLane.sorted(by: { $0.key < $1.key }) {
            lines.append("ferry_gpu_lane_pending{lane=\"\(lane)\"} \(pending)")
        }
        lines += [
            "# HELP ferry_gpu_seconds_total Seconds spent holding the device, by pod.",
            "# TYPE ferry_gpu_seconds_total counter",
            "# HELP ferry_gpu_queued_seconds_total Seconds spent waiting for it, by pod.",
            "# TYPE ferry_gpu_queued_seconds_total counter",
            "# HELP ferry_gpu_requests_total Requests, by pod.",
            "# TYPE ferry_gpu_requests_total counter",
            "# HELP ferry_gpu_failures_total Requests that failed, by pod.",
            "# TYPE ferry_gpu_failures_total counter",
            "# HELP ferry_gpu_yields_total Times a pod's work was preempted for another.",
            "# TYPE ferry_gpu_yields_total counter",
        ]
        // The pod uid is the only label: names come and go, uids do not, and a
        // label per anything else would be cardinality for its own sake.
        let held = lock.withLock { pods }
        for (uid, usage) in lanes.ledger.all.sorted(by: { $0.key < $1.key }) {
            let pod = held[uid]?.registration
            let labels = "pod=\"\(pod?.name ?? "")\",namespace=\"\(pod?.namespace ?? "")\",uid=\"\(uid)\""
            lines.append("ferry_gpu_seconds_total{\(labels)} \(usage.gpuSeconds)")
            lines.append("ferry_gpu_queued_seconds_total{\(labels)} \(usage.queuedSeconds)")
            lines.append("ferry_gpu_requests_total{\(labels)} \(usage.requests)")
            lines.append("ferry_gpu_failures_total{\(labels)} \(usage.failures)")
            lines.append("ferry_gpu_yields_total{\(labels)} \(usage.yields)")
        }
        return HTTPResponse(status: 200,
                            headers: ["Content-Type": "text/plain; version=0.0.4"],
                            body: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    /// Puts one request through the scheduler and turns whatever comes back
    /// into a response, with the status the caller needs to tell a "try again"
    /// from a "you asked for too much".
    private func run<T: Encodable>(
        pod: String, lane: GPULane, what: String, _ work: @escaping (GPUJob) throws -> T
    ) -> HTTPResponse {
        log("\(what) for \(pod)")
        do {
            return .json(try lanes.run(lane: lane, pod: pod, timeout: requestTimeout, work))
        } catch let error as SchedulerError {
            log("\(what) for \(pod): \(error)")
            return .error("\(error)", status: error.status)
        } catch let error as GPUError {
            return .error("\(error)", status: 400)
        } catch let error as GenerationError {
            if case .unavailable = error { return .error("\(error)", status: 503) }
            return .error("\(error)", status: 400)
        } catch {
            return .error("\(error)", status: 500)
        }
    }
}

/// Runs an async call from a connection thread and waits for it.
///
/// The server is thread-per-connection and blocking; the model's API is async.
/// This is the seam between the two, and it is deliberately the only one.
func awaitResult<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, Error>?
    Task {
        do { result = .success(try await work()) } catch { result = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    return try result!.get()
}

func log(_ message: String) {
    print("\(ISO8601DateFormatter().string(from: Date())) \(message)")
}
