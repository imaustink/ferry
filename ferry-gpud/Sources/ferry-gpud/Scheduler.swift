// Who gets the GPU next, for how long, and what happens when a pod goes away
// mid-request.
//
// There is one GPU and there are many pods, so something has to decide the
// order. A plain lock decides it badly: whoever happens to wake first wins, a
// pod that submits ten jobs starves a pod that submitted one, a job with no
// deadline runs until it finishes however long that is, and a pod deleted
// mid-request leaves its work running for a container that no longer exists.
//
// So: a device token handed out in round-robin order over *pods*, a bounded
// queue, a deadline on every job, cancellation keyed by pod -- and a time slice,
// after which a long job hands the device back if anyone else is waiting.
//
// Round-robin over pods rather than FIFO over jobs is the first half of
// fairness. FIFO is fair to *requests*, which is not the same as fair to
// tenants: ten queued jobs from one pod would push everyone else behind all ten.
//
// The time slice is the second half, and it is why the work runs on the caller's
// own thread rather than on a worker. Ordering a queue only helps when jobs are
// short: a single 60-second matmul makes every other pod wait 60 seconds however
// fair the order is. A job holding the token gives it up at a checkpoint once
// its slice is spent and another pod wants it -- and because its progress is
// simply this thread's stack, resuming costs nothing. No worker pool, no
// serialising progress, nothing re-run.
//
// What cannot be preempted is a single Metal command buffer, which runs to
// completion whatever anyone wants. That, not the slice, sets the floor on how
// long another pod can be made to wait.

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
    /// Seconds actually holding the device. With preemption this is no longer
    /// the same as the wall time between asking and being answered.
    var gpuSeconds: Double = 0
    /// Seconds spent waiting for it, including time given up mid-request at a
    /// yield. The number that says whether the node is oversubscribed.
    var queuedSeconds: Double = 0
    /// How often this pod's work has been preempted for someone else.
    var yields: Int = 0
    var lastUsed: String?
}

/// One unit of GPU work, and the handle its body uses to cooperate.
final class GPUJob: @unchecked Sendable {
    let pod: String
    let deadline: Date
    private let lock = NSLock()
    private var cancelledFlag = false
    fileprivate weak var scheduler: GPUScheduler?

    init(pod: String, deadline: Date) {
        self.pod = pod
        self.deadline = deadline
    }

    var isCancelled: Bool { lock.withLock { cancelledFlag } }

    func cancel() { lock.withLock { cancelledFlag = true } }

    /// Throws if the job should stop: its pod went away, or it is out of time.
    func checkpoint() throws {
        if isCancelled { throw SchedulerError.cancelled }
        if Date() > deadline {
            throw SchedulerError.timedOut(-deadline.timeIntervalSinceNow)
        }
    }

    /// Checkpoint, and hand the device to someone else if this job has had its
    /// slice and another pod is waiting.
    ///
    /// Call it wherever the work can be interrupted without losing anything --
    /// for a matmul that is between passes, which is the only place there is,
    /// since a committed command buffer cannot be stopped.
    func yieldIfNeeded() throws {
        try checkpoint()
        try scheduler?.yieldIfNeeded(self)
    }

    /// How long is left, for work that can size itself to fit.
    var remaining: TimeInterval { max(0, deadline.timeIntervalSinceNow) }
}

final class GPUScheduler: @unchecked Sendable {
    /// One per in-flight request, living on the caller's thread.
    private final class Waiter {
        let job: GPUJob
        /// Set while this waiter holds the device.
        var granted = false
        var grantedAt = Date()
        /// Time spent holding the device, summed across slices.
        var held: TimeInterval = 0
        /// Time spent waiting for it, before the first grant and at every yield.
        var waited: TimeInterval = 0
        var waitingSince = Date()
        var failed: Error?
        init(job: GPUJob) { self.job = job }
    }

    private let condition = NSCondition()
    /// Per pod, in arrival order.
    private var queues: [String: [Waiter]] = [:]
    /// The rotation. A pod is here while it has work waiting for the device.
    private var rotation: [String] = []
    private var waiting = 0
    /// Who holds the device. Exactly one, or nobody.
    private var current: Waiter?
    private var stopping = false

    private let queueDepth: Int
    private let perPodDepth: Int
    private let slice: TimeInterval
    private var usage: [String: PodUsage] = [:]
    /// Pods come and go for the life of the cluster, so their accounting cannot
    /// be kept forever. Past this, the least recently used record is dropped.
    private let maxUsageEntries = 256

    init(queueDepth: Int, perPodDepth: Int, slice: TimeInterval) {
        self.queueDepth = queueDepth
        self.perPodDepth = perPodDepth
        self.slice = slice
    }

    // MARK: - Running

    /// Waits for the device, runs `body` on this thread, and hands it back.
    ///
    /// The caller is an HTTP connection thread, which is allowed to block --
    /// that is what the client is doing too.
    func run<T>(pod: String, timeout: TimeInterval,
                _ body: (GPUJob) throws -> T) throws -> T {
        let job = GPUJob(pod: pod, deadline: Date().addingTimeInterval(timeout))
        job.scheduler = self
        let waiter = Waiter(job: job)

        try admit(waiter)

        var failure: Error?
        var result: T?
        do {
            result = try body(job)
        } catch {
            failure = error
        }
        finish(waiter, failure: failure)

        if let failure { throw failure }
        guard let result else { throw SchedulerError.cancelled }
        return result
    }

    /// Joins the queue and waits for the device.
    private func admit(_ waiter: Waiter) throws {
        condition.lock()
        defer { condition.unlock() }

        guard !stopping else { throw SchedulerError.draining }
        guard waiting < queueDepth else { throw SchedulerError.queueFull(waiting) }
        let queued = queues[waiter.job.pod]?.count ?? 0
        guard queued < perPodDepth else { throw SchedulerError.podQueueFull(queued) }

        enqueue(waiter)
        promote()
        try waitForDevice(waiter)
    }

    /// Called with the lock held.
    private func enqueue(_ waiter: Waiter) {
        waiter.waitingSince = Date()
        queues[waiter.job.pod, default: []].append(waiter)
        if !rotation.contains(waiter.job.pod) { rotation.append(waiter.job.pod) }
        waiting += 1
    }

    /// Called with the lock held. Blocks until this waiter holds the device, or
    /// gives up because its pod went away or its deadline passed.
    private func waitForDevice(_ waiter: Waiter) throws {
        while !waiter.granted {
            if let failure = waiter.failed {
                remove(waiter)
                throw failure
            }
            if waiter.job.isCancelled {
                remove(waiter)
                throw SchedulerError.cancelled
            }
            if Date() >= waiter.job.deadline {
                remove(waiter)
                throw SchedulerError.timedOut(-waiter.job.deadline.timeIntervalSinceNow)
            }
            // Woken by a handoff, by a cancellation, or by its own deadline --
            // whichever comes first. The one-second cap keeps a waiter whose
            // deadline is far off from sleeping through a cancel it was not
            // signalled for.
            condition.wait(until: min(waiter.job.deadline, Date().addingTimeInterval(1)))
        }
        waiter.waited += Date().timeIntervalSince(waiter.waitingSince)
    }

    /// Called with the lock held. Takes a waiter out of whichever queue holds it.
    private func remove(_ waiter: Waiter) {
        let pod = waiter.job.pod
        guard var queued = queues[pod],
              let index = queued.firstIndex(where: { $0 === waiter })
        else { return }
        queued.remove(at: index)
        waiting -= 1
        if queued.isEmpty {
            queues.removeValue(forKey: pod)
            rotation.removeAll { $0 == pod }
        } else {
            queues[pod] = queued
        }
    }

    /// Called with the lock held. Gives the device to the next pod in the
    /// rotation, if it is free and anyone wants it.
    private func promote() {
        guard current == nil, !rotation.isEmpty else { return }
        let pod = rotation.removeFirst()
        guard var queued = queues[pod], !queued.isEmpty else { return }
        let next = queued.removeFirst()
        waiting -= 1
        if queued.isEmpty {
            queues.removeValue(forKey: pod)
        } else {
            queues[pod] = queued
            // Back of the rotation: this pod has just had its turn.
            rotation.append(pod)
        }
        current = next
        next.granted = true
        next.grantedAt = Date()
        condition.broadcast()
    }

    /// Hands the device back and records what the request cost.
    private func finish(_ waiter: Waiter, failure: Error?) {
        condition.lock()
        defer { condition.unlock() }

        if current === waiter {
            waiter.held += Date().timeIntervalSince(waiter.grantedAt)
            current = nil
        }
        var record = usage[waiter.job.pod] ?? PodUsage()
        record.requests += 1
        record.gpuSeconds += waiter.held
        record.queuedSeconds += waiter.waited
        record.lastUsed = ISO8601DateFormatter().string(from: Date())
        if failure != nil { record.failures += 1 }
        usage[waiter.job.pod] = record
        evictUsageIfNeeded()
        promote()
        condition.broadcast()
    }

    // MARK: - Preemption

    /// Called from the body, through GPUJob. Gives the device up if this job has
    /// had its slice and a *different* pod is waiting -- yielding to another job
    /// of the same pod would be churn for nothing.
    fileprivate func yieldIfNeeded(_ job: GPUJob) throws {
        condition.lock()
        defer { condition.unlock() }

        guard let waiter = current, waiter.job === job else { return }
        guard Date().timeIntervalSince(waiter.grantedAt) >= slice else { return }
        guard rotation.contains(where: { $0 != job.pod }) else { return }

        waiter.held += Date().timeIntervalSince(waiter.grantedAt)
        waiter.granted = false
        current = nil
        enqueue(waiter)
        usage[job.pod, default: PodUsage()].yields += 1
        promote()
        try waitForDevice(waiter)
    }

    // MARK: - Cancellation and shutdown

    /// Stops everything belonging to a pod: waiting requests give up, and a
    /// running one stops at its next checkpoint.
    ///
    /// This is what a pod being deleted mid-request means. Without it the GPU
    /// keeps working for a container that no longer exists, and the next pod
    /// waits behind it.
    @discardableResult
    func cancel(pod: String) -> Int {
        condition.lock()
        defer { condition.unlock() }

        var stopped = 0
        for waiter in queues[pod] ?? [] {
            waiter.job.cancel()
            waiter.failed = SchedulerError.cancelled
            stopped += 1
        }
        if let current, current.job.pod == pod {
            current.job.cancel()
            stopped += 1
        }
        condition.broadcast()
        return stopped
    }

    /// Refuses new work and waits for what is in flight, briefly.
    func drain(timeout: TimeInterval) {
        condition.lock()
        stopping = true
        condition.broadcast()
        condition.unlock()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            condition.lock()
            let idle = current == nil && waiting == 0
            condition.unlock()
            if idle { return }
            usleep(50_000)
        }
        condition.lock()
        current?.job.cancel()
        condition.broadcast()
        condition.unlock()
    }

    // MARK: - Reporting

    var stats: [String: PodUsage] {
        condition.lock()
        defer { condition.unlock() }
        return usage
    }

    func usage(for pod: String) -> PodUsage {
        condition.lock()
        defer { condition.unlock() }
        return usage[pod] ?? PodUsage()
    }

    func forget(pod: String) {
        condition.lock()
        defer { condition.unlock() }
        usage.removeValue(forKey: pod)
    }

    /// Requests queued or running right now, for /capacity.
    var pending: Int {
        condition.lock()
        defer { condition.unlock() }
        return waiting + (current == nil ? 0 : 1)
    }

    /// Called with the lock held. Drops the least recently used record rather
    /// than letting a long-lived node accumulate one per pod it has served.
    private func evictUsageIfNeeded() {
        guard usage.count > maxUsageEntries else { return }
        let oldest = usage.min { ($0.value.lastUsed ?? "") < ($1.value.lastUsed ?? "") }
        if let key = oldest?.key { usage.removeValue(forKey: key) }
    }
}
