// The service: what the sockets serve, and which sockets exist.
//
// There are two kinds. The control socket is ferry-cri's, and mints a socket
// for a pod that asked for a GPU. A pod socket is that pod's, and is the only
// thing the pod ever sees -- it carries no pod identifier, because it does not
// need one: there is exactly one pod that socket could have come from, which is
// the whole argument for the relay over a listener on the pod network
// (docs/GPU.md).

import Foundation

struct PodRegistration: Decodable {
    var uid: String
    var namespace: String?
    var name: String?
}

struct PodEntry: Encodable {
    var uid: String
    var namespace: String?
    var name: String?
    var socket: String
    var requests: Int
}

struct Capacity: Encodable {
    var limit: Int
    var granted: Int
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

/// Holds the GPU, the model, and the set of pods currently granted a socket.
final class Service: @unchecked Sendable {
    private let gpu: GPU
    private let generator = Generator()
    private let socketDirectory: String
    /// How many pods may hold a relay at once. There is one GPU; this is a
    /// policy number, not a discovered one, and it is what the node advertises
    /// as ferry.dev/gpu.
    private let limit: Int

    private let lock = NSLock()
    private var pods: [String: (registration: PodRegistration, server: UnixHTTPServer)] = [:]
    private var requestCounts: [String: Int] = [:]

    init(gpu: GPU, socketDirectory: String, limit: Int) {
        self.gpu = gpu
        self.socketDirectory = socketDirectory
        self.limit = limit
    }

    // MARK: - Pods

    func socketPath(uid: String) -> String { "\(socketDirectory)/\(uid).sock" }

    /// Binds a socket for a pod. Idempotent: the kubelet retries, and a retry
    /// must not cost a second slot or a second listener on the same path.
    func grant(_ registration: PodRegistration) throws -> PodEntry {
        guard !registration.uid.isEmpty else { throw ServiceError.badRequest("uid is required") }
        // The uid becomes a filename, so it may not wander out of the directory.
        guard !registration.uid.contains("/"), !registration.uid.contains(".."),
              registration.uid.count <= 64 else {
            throw ServiceError.badRequest("uid is not a plausible pod uid")
        }

        return try lock.withLock {
            if let existing = pods[registration.uid] {
                return entry(uid: registration.uid, registration: existing.registration)
            }
            guard pods.count < limit else { throw ServiceError.full(limit) }

            let path = socketPath(uid: registration.uid)
            let server = UnixHTTPServer(path: path, identity: registration.uid) { [weak self] request, identity in
                self?.handlePod(request, identity: identity) ?? .error("shutting down", status: 503)
            }
            try server.start()
            pods[registration.uid] = (registration, server)
            requestCounts[registration.uid] = 0
            log("granted \(describe(registration)) -> \(path)")
            return entry(uid: registration.uid, registration: registration)
        }
    }

    func revoke(uid: String) -> Bool {
        lock.withLock {
            guard let held = pods.removeValue(forKey: uid) else { return false }
            held.server.stop()
            requestCounts.removeValue(forKey: uid)
            log("revoked \(describe(held.registration))")
            return true
        }
    }

    func revokeAll() {
        lock.withLock {
            for (_, held) in pods { held.server.stop() }
            pods.removeAll()
            requestCounts.removeAll()
        }
    }

    var listing: [PodEntry] {
        lock.withLock {
            pods.map { entry(uid: $0.key, registration: $0.value.registration) }
                .sorted { $0.uid < $1.uid }
        }
    }

    var capacity: Capacity {
        lock.withLock { Capacity(limit: limit, granted: pods.count) }
    }

    /// Called with the lock held.
    private func entry(uid: String, registration: PodRegistration) -> PodEntry {
        PodEntry(uid: uid, namespace: registration.namespace, name: registration.name,
                 socket: socketPath(uid: uid), requests: requestCounts[uid] ?? 0)
    }

    private func describe(_ registration: PodRegistration) -> String {
        if let namespace = registration.namespace, let name = registration.name {
            return "\(namespace)/\(name) (\(registration.uid))"
        }
        return registration.uid
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
        if let identity {
            lock.withLock { requestCounts[identity, default: 0] += 1 }
        }

        switch (request.method, request.segments) {
        case ("GET", ["healthz"]):
            return .json(["status": "ok"])

        case ("GET", ["v1", "device"]):
            return .json(gpu.info)

        case ("GET", ["v1", "model"]):
            return .json(generator.status)

        case ("POST", ["v1", "matmul"]):
            struct Body: Decodable { var size: Int?; var iterations: Int? }
            let body = (try? request.json(Body.self)) ?? Body(size: nil, iterations: nil)
            let size = body.size ?? 1024
            let iterations = body.iterations ?? 10
            log("matmul \(size)x\(size) x\(iterations) for \(identity ?? "control")")
            do {
                return .json(try gpu.matmul(size: size, iterations: iterations))
            } catch let error as GPUError {
                return .error("\(error)", status: 400)
            } catch {
                return .error("\(error)", status: 500)
            }

        case ("POST", ["v1", "generate"]):
            guard let body = try? request.json(GenerateRequest.self) else {
                return .error("expected {\"prompt\": \"...\"}", status: 400)
            }
            log("generate \(body.prompt.count) chars for \(identity ?? "control")")
            do {
                return .json(try awaitResult { try await self.generator.generate(body) })
            } catch let error as GenerationError {
                if case .unavailable = error { return .error("\(error)", status: 503) }
                return .error("\(error)", status: 400)
            } catch {
                return .error("\(error)", status: 500)
            }

        default:
            return .error("no route for \(request.method) \(request.path)", status: 404)
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
    let stamp = ISO8601DateFormatter().string(from: Date())
    print("\(stamp) \(message)")
}
