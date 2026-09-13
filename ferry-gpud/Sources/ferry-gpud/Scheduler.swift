// Who gets the GPU next, for how long, and what happens when a pod goes away
// mid-request.
//
// There is one GPU and there are many pods, so something has to decide the
// order. A plain lock decides it badly: whoever happens to wake first wins, a
// pod that submits ten jobs starves a pod that submitted one, a job with no
// deadline runs until it finishes however long that is, and a pod deleted
// mid-request leaves its work running for a container that no longer exists.
//
// So: one worker, a bounded queue, round-robin across pods, a deadline on every
// job, and cancellation keyed by pod.
//
// Round-robin over pods rather than FIFO over jobs is the whole point. FIFO is
// fair to *requests*, which is not the same as fair to tenants: ten queued jobs
// from one pod would push everyone else behind all ten. Rotating over pods
// means a pod's second job waits behind every other pod's first.

import Foundation

enum SchedulerError: Error, CustomStringConvertible {
    case queueFull(Int)
    case podQueueFull(Int)
    case cancelled
    case timedOut(TimeInterval)
    case draining

    var description: String {
        switch self {
        case .queueFull(let depth):
            "the GPU queue is full (\(depth) waiting); try again shortly"
        case .podQueueFull(let depth):
            "this pod already has \(depth) requests queued"
        case .cancelled:
            "the request was cancelled because the pod went away"
        case .timedOut(let seconds):
            "the request exceeded its \(Int(seconds))s deadline"
        case .draining:
            "ferry-gpud is shutting down"
        }
    }

    /// HTTP status for each, so the caller can tell a "come back later" from a
    /// "you asked for too much".
    var status: Int {
        switch self {
        case .queueFull, .podQueueFull, .draining: 503
        case .cancelled: 499
        case .timedOut: 504
        }
    }
}

/// What a pod has cost the GPU. Not billing -- the point is that when the GPU
/// is busy there is an answer to "busy with what", which `kubectl top` will
/// never give.
struct PodUsage: Encodable, Sendable {
    var requests: Int = 0
    var failures: Int = 0
    /// Seconds actually spent on the device, not wall time including the queue.
    var gpuSeconds: Double = 0
    /// Seconds spent waiting for the device. The number that says whether the
    /// node is oversubscribed.
    var queuedSeconds: Double = 0
    var lastUsed: String?
}

/// One unit of GPU work. Handed to the body so long-running work can cooperate:
/// nothing here can interrupt a Metal command buffer that has already been
/// committed, so the body has to come up for air and ask.
final class GPUJob: @unchecked Sendable {
    let pod: String
    let deadline: Date
    private let lock = NSLock()
    private var cancelledFlag = false

    init(pod: String, deadline: Date) {
        self.pod = pod
        self.deadline = deadline
    }

    var isCancelled: Bool { lock.withLock { cancelledFlag } }

    func cancel() { lock.withLock { cancelledFlag = true } }

    /// Call between chunks of work. Throws if the job should stop.
    func checkpoint() throws {
        if isCancelled { throw SchedulerError.cancelled }
        if Date() > deadline {
            throw SchedulerError.timedOut(deadline.timeIntervalSinceNow * -1)
        }
    }

    /// How long is left, for work that can size itself to fit.
    var remaining: TimeInterval { max(0, deadline.timeIntervalSinceNow) }
}

final class GPUScheduler: @unchecked Sendable {
    private final class Entry {
        let job: GPUJob
        /// Returns what went wrong, so the worker can count it. The result
        /// itself goes out through the caller's box.
        let run: (GPUJob) -> Error?
        let done = DispatchSemaphore(value: 0)
        let queuedAt = Date()
        var failed: Error?
        init(job: GPUJob, run: @escaping (GPUJob) -> Error?) {
            self.job = job
            self.run = run
        }
    }

    /// Pods come and go for the life of the cluster, so their accounting cannot
    /// be kept forever. Past this, the least recently used record is dropped.
    private let maxUsageEntries = 256

    private let condition = NSCondition()
    /// Per pod, in arrival order.
    private var queues: [String: [Entry]] = [:]
    /// The rotation. A pod is here while it has queued work.
    private var rotation: [String] = []
    private var waiting = 0
    private var running: Entry?
    private var stopping = false

    private let queueDepth: Int
    private let perPodDepth: Int
    private var usage: [String: PodUsage] = [:]

    init(queueDepth: Int, perPodDepth: Int) {
        self.queueDepth = queueDepth
        self.perPodDepth = perPodDepth
        Thread.detachNewThread { [self] in worker() }
    }

    // MARK: - Submitting

    /// Runs `body` on the GPU worker and waits for it.
    ///
    /// The caller is an HTTP connection thread, which is allowed to block --
    /// that is what the client is doing too.
    func run<T>(pod: String, timeout: TimeInterval,
                _ body: @escaping (GPUJob) throws -> T) throws -> T {
        let job = GPUJob(pod: pod, deadline: Date().addingTimeInterval(timeout))
        let box = Box<T>()
        let entry = Entry(job: job) { job in
            do {
                box.value = try body(job)
                return nil
            } catch {
                box.error = error
                return error
            }
        }

        try condition.withLock {
            guard !stopping else { throw SchedulerError.draining }
            guard waiting < queueDepth else { throw SchedulerError.queueFull(waiting) }
            let queued = queues[pod]?.count ?? 0
            guard queued < perPodDepth else { throw SchedulerError.podQueueFull(queued) }

            queues[pod, default: []].append(entry)
            if !rotation.contains(pod) { rotation.append(pod) }
            waiting += 1
            condition.signal()
        }

        // Waiting for the device counts against the deadline as much as running
        // does: a client that asked for 60s means 60s, not 60s once it is its
        // turn. A little slack so the worker's own deadline check is what
        // reports the timeout, with the reason attached.
        if entry.done.wait(timeout: .now() + timeout + 5) == .timedOut {
            job.cancel()
            throw SchedulerError.timedOut(timeout)
        }
        if let error = entry.failed ?? box.error { throw error }
        guard let value = box.value else { throw SchedulerError.cancelled }
        return value
    }

    /// Stops everything belonging to a pod: queued work fails immediately, and
    /// running work is asked to stop at its next checkpoint.
    ///
    /// This is what a pod being deleted mid-request means. Without it the GPU
    /// keeps working for a container that no longer exists, and the next pod
    /// waits behind it.
    @discardableResult
    func cancel(pod: String) -> Int {
        condition.withLock {
            var stopped = 0
            if let queued = queues.removeValue(forKey: pod) {
                for entry in queued {
                    entry.job.cancel()
                    entry.failed = SchedulerError.cancelled
                    entry.done.signal()
                    stopped += 1
                }
                waiting -= queued.count
            }
            rotation.removeAll { $0 == pod }
            if let running, running.job.pod == pod {
                running.job.cancel()
                stopped += 1
            }
            return stopped
        }
    }

    /// Refuses new work and waits for what is in flight, briefly.
    func drain(timeout: TimeInterval) {
        condition.withLock {
            stopping = true
            condition.broadcast()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let idle = condition.withLock { running == nil && waiting == 0 }
            if idle { return }
            usleep(50_000)
        }
        condition.withLock { running?.job.cancel() }
    }

    // MARK: - Reporting

    var stats: [String: PodUsage] { condition.withLock { usage } }

    func usage(for pod: String) -> PodUsage { condition.withLock { usage[pod] ?? PodUsage() } }

    func forget(pod: String) { condition.withLock { _ = usage.removeValue(forKey: pod) } }

    /// Called with the condition held. Drops the least recently used record
    /// rather than letting a long-lived node accumulate one per pod it has ever
    /// served.
    private func evictUsageIfNeeded() {
        guard usage.count > maxUsageEntries else { return }
        let oldest = usage.min { ($0.value.lastUsed ?? "") < ($1.value.lastUsed ?? "") }
        if let key = oldest?.key { usage.removeValue(forKey: key) }
    }

    /// Queue depth now, for /capacity.
    var pending: Int { condition.withLock { waiting + (running == nil ? 0 : 1) } }

    // MARK: - The worker

    private func worker() {
        while true {
            var entry: Entry?
            condition.withLock {
                while !stopping && rotation.isEmpty { condition.wait() }
                guard !rotation.isEmpty else { return }
                // Take the pod at the front of the rotation and move it to the
                // back, so the next job comes from someone else.
                let pod = rotation.removeFirst()
                guard var queued = queues[pod], !queued.isEmpty else { return }
                let next = queued.removeFirst()
                if queued.isEmpty {
                    queues.removeValue(forKey: pod)
                } else {
                    queues[pod] = queued
                    rotation.append(pod)
                }
                waiting -= 1
                running = next
                entry = next
            }

            guard let entry else {
                if condition.withLock({ stopping }) { return }
                continue
            }

            let queued = Date().timeIntervalSince(entry.queuedAt)
            let started = Date()
            var failure: Error?
            if entry.job.isCancelled {
                failure = SchedulerError.cancelled
                entry.failed = failure
            } else {
                failure = entry.run(entry.job)
            }
            let spent = Date().timeIntervalSince(started)

            condition.withLock {
                var record = usage[entry.job.pod] ?? PodUsage()
                record.requests += 1
                record.gpuSeconds += spent
                record.queuedSeconds += queued
                record.lastUsed = ISO8601DateFormatter().string(from: Date())
                if failure != nil { record.failures += 1 }
                usage[entry.job.pod] = record
                evictUsageIfNeeded()
                running = nil
            }
            entry.done.signal()
        }
    }
}

/// Carries a result out of the type-erased job closure.
private final class Box<T>: @unchecked Sendable {
    var value: T?
    var error: Error?
}

extension NSCondition {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
