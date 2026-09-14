// One token was one too few.
//
// ferry-gpud used to hand out a single device token: one job at a time, whatever
// kind. That is right for two matmuls, and measurably wrong for a matmul and a
// generation.
//
// Two Metal matmuls at once, on this M4 Max:
//
//     one alone      13385 GFLOP/s
//     two at once     6858 + 6760 = 13619 GFLOP/s   (102% of one)
//
// They split one GPU between them and the total does not move, so running them
// concurrently buys two percent and costs every timing its meaning. Serialising
// is correct.
//
// A matmul and a generation at once:
//
//     matmul         13330 -> 13401 GFLOP/s        (+0.5%)
//     generation     2.84ms -> 2.72ms per character
//
// Neither notices the other. Apple's model does not live on the GPU's shaders --
// the Neural Engine is its own silicon -- so the two are not the same resource
// and a token that covers both is a token too coarse.
//
// So: a lane per unit. Within a lane, everything the scheduler already does --
// round-robin over pods, priority, slices, deadlines, cancellation. Across
// lanes, nothing: a pod generating text and a pod multiplying matrices do not
// wait for each other, because the hardware does not make them.

import Foundation

/// Which piece of silicon a request needs.
enum GPULane: String, CaseIterable, Sendable {
    /// Metal compute. One at a time: two of these saturate the same shaders.
    case compute
    /// The on-device model, which measurement says runs beside Metal rather
    /// than against it.
    case model

    var description: String { rawValue }
}

/// The lanes, and everything that has to span them.
final class GPULanes: @unchecked Sendable {
    private let schedulers: [GPULane: GPUScheduler]
    /// Shared, so a pod's accounting is its total across lanes rather than one
    /// number per lane that nobody adds up.
    let ledger = UsageLedger()

    init(queueDepth: Int, perPodDepth: Int, slice: TimeInterval, starvationGuard: TimeInterval) {
        var built: [GPULane: GPUScheduler] = [:]
        for lane in GPULane.allCases {
            built[lane] = GPUScheduler(
                lane: lane, queueDepth: queueDepth, perPodDepth: perPodDepth,
                slice: slice, starvationGuard: starvationGuard, ledger: ledger)
        }
        self.schedulers = built
    }

    func run<T>(lane: GPULane, pod: String, timeout: TimeInterval,
                _ body: (GPUJob) throws -> T) throws -> T {
        try schedulers[lane]!.run(pod: pod, timeout: timeout, body)
    }

    func setPriority(_ priority: Int32, for pod: String) {
        for scheduler in schedulers.values { scheduler.setPriority(priority, for: pod) }
    }

    /// Stops a pod's work in every lane. A deleted pod is deleted everywhere.
    @discardableResult
    func cancel(pod: String) -> Int {
        schedulers.values.reduce(0) { $0 + $1.cancel(pod: pod) }
    }

    func forget(pod: String) {
        for scheduler in schedulers.values { scheduler.forget(pod: pod) }
        ledger.forget(pod: pod)
    }

    /// Drains the lanes at the same time rather than one after the other -- they
    /// are independent, so a serial drain would just take twice as long.
    func drain(timeout: TimeInterval) {
        let group = DispatchGroup()
        for scheduler in schedulers.values {
            group.enter()
            DispatchQueue.global().async {
                scheduler.drain(timeout: timeout)
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + timeout + 2)
    }

    /// Queued or running, across every lane.
    var pending: Int { schedulers.values.reduce(0) { $0 + $1.pending } }

    /// What is waiting in each lane, which is the number that says *which*
    /// resource is short rather than that something is.
    var pendingByLane: [String: Int] {
        Dictionary(uniqueKeysWithValues: schedulers.map { ($0.key.rawValue, $0.value.pending) })
    }
}

/// Where every lane's accounting is added up.
///
/// Separate from the schedulers because a pod's GPU time is one number whatever
/// mix of lanes it used, and because two schedulers keeping two maps would be
/// two places for it to be wrong.
final class UsageLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var usage: [String: PodUsage] = [:]
    /// Pods come and go for the life of the cluster, so their accounting cannot
    /// be kept forever. Past this, the least recently used record is dropped.
    private let maxEntries = 256

    func record(pod: String, _ change: (inout PodUsage) -> Void) {
        lock.withLock {
            var record = usage[pod] ?? PodUsage()
            change(&record)
            record.lastUsed = ISO8601DateFormatter().string(from: Date())
            usage[pod] = record
            if usage.count > maxEntries,
               let oldest = usage.min(by: { ($0.value.lastUsed ?? "") < ($1.value.lastUsed ?? "") }) {
                usage.removeValue(forKey: oldest.key)
            }
        }
    }

    func usage(for pod: String) -> PodUsage { lock.withLock { usage[pod] ?? PodUsage() } }

    var all: [String: PodUsage] { lock.withLock { usage } }

    func forget(pod: String) { lock.withLock { _ = usage.removeValue(forKey: pod) } }
}
