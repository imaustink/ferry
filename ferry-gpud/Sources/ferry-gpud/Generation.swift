// Text generation on the on-device model.
//
// The other thing a pod cannot do for itself, and the one most likely to be
// what someone actually wanted when they asked for a GPU. macOS 26 ships the
// model; there is nothing to download and no weights to ship, which is why this
// is the first backend rather than llama.cpp or MLX -- those can sit behind the
// same endpoint later without the pod noticing.
//
// Availability is a runtime question (Apple Intelligence can be off, or the
// model still downloading), so it is reported rather than assumed, and the
// endpoint 503s with the reason instead of failing obscurely.
//
// Generation is *streamed* rather than awaited whole, and not for the usual
// reason -- nothing here shows partial output to anybody. It is streamed
// because the gap between snapshots is the only checkpoint a generation has,
// and without one a long generation would hold the device for its entire run
// while every matmul queued behind it. Measured on this model: a 5s generation
// arrives as 27 snapshots, a median of 0.153s apart. That is finer than the
// scheduler's time slice, so generation yields as readily as a matmul does.

import Foundation
import FoundationModels

struct GenerateRequest: Decodable {
    var prompt: String
    var instructions: String?
    var temperature: Double?
    var maxTokens: Int?
}

struct GenerateResult: Encodable {
    var content: String
    var seconds: Double
    /// How many times the device was handed to another pod mid-generation.
    /// Visible so a caller can tell a slow model from a busy node.
    var yields: Int
}

struct ModelStatus: Encodable {
    var available: Bool
    var reason: String?
}

enum GenerationError: Error, CustomStringConvertible {
    case unavailable(String)
    case failed(String)

    var description: String {
        switch self {
        case .unavailable(let m): m
        case .failed(let m): m
        }
    }
}

/// Pulls one snapshot at a time from a response stream.
///
/// The point is to get back onto the calling thread between snapshots, because
/// that thread is the one holding the device and the only one that can hand it
/// over. Consuming the whole stream inside a single async call would give the
/// scheduler nowhere to interpose.
///
/// Only ever used by one thread at a time -- the one holding the device -- which
/// is what makes the unchecked conformance true.
private final class SnapshotPuller: @unchecked Sendable {
    private var iterator: LanguageModelSession.ResponseStream<String>.AsyncIterator

    init(_ stream: LanguageModelSession.ResponseStream<String>) {
        self.iterator = stream.makeAsyncIterator()
    }

    func next() async throws -> String? {
        try await iterator.next()?.content
    }
}

/// Runs generation on the thread that holds the device.
///
/// Not an actor any more: the scheduler already guarantees one job at a time,
/// and actor isolation would only add a hop that makes yielding harder.
final class Generator: @unchecked Sendable {
    var status: ModelStatus {
        switch SystemLanguageModel.default.availability {
        case .available:
            return ModelStatus(available: true, reason: nil)
        case .unavailable(let reason):
            return ModelStatus(available: false, reason: Self.describe(reason))
        @unknown default:
            return ModelStatus(available: false, reason: "unknown")
        }
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: "this Mac is not eligible for the on-device model"
        case .appleIntelligenceNotEnabled: "Apple Intelligence is not enabled"
        case .modelNotReady: "the model is not ready yet; it may still be downloading"
        @unknown default: "unavailable"
        }
    }

    /// The most a prompt may be. Generation time scales with it, and the
    /// deadline is a blunter instrument than simply not accepting the job.
    static let maxPromptBytes = 16 * 1024

    /// The most a pod may ask the model to produce.
    ///
    /// `maximumResponseTokens` went to the framework unchecked, which left the
    /// model lane with no bound of its own: the request deadline would stop a
    /// runaway eventually, but only after it had held the lane for its whole
    /// budget. The compute lane has a memory ceiling for the same reason; this
    /// is the model lane's version of it.
    static let maxResponseTokens = 4096

    func generate(_ request: GenerateRequest, job: GPUJob) throws -> GenerateResult {
        let status = self.status
        guard status.available else {
            throw GenerationError.unavailable(status.reason ?? "the on-device model is unavailable")
        }
        guard !request.prompt.isEmpty else { throw GenerationError.failed("prompt is required") }
        guard request.prompt.utf8.count <= Self.maxPromptBytes else {
            throw GenerationError.failed(
                "prompt is \(request.prompt.utf8.count) bytes, over the \(Self.maxPromptBytes) limit")
        }
        if let instructions = request.instructions,
           instructions.utf8.count > Self.maxPromptBytes {
            throw GenerationError.failed("instructions exceed the \(Self.maxPromptBytes) byte limit")
        }

        // A fresh session per request: pods do not share a conversation, and a
        // transcript that accumulated across tenants would be a leak, not a
        // feature.
        let session = request.instructions.map { LanguageModelSession(instructions: $0) }
            ?? LanguageModelSession()
        if let asked = request.maxTokens, asked > Self.maxResponseTokens {
            throw GenerationError.failed(
                "maxTokens \(asked) is over this node's limit of \(Self.maxResponseTokens)")
        }
        // Defaulted rather than left nil: without a cap the model decides how
        // long to run, and "as long as it likes" is not a policy.
        let options = GenerationOptions(
            temperature: request.temperature,
            maximumResponseTokens: request.maxTokens ?? Self.maxResponseTokens)

        let start = Date()
        let puller = SnapshotPuller(session.streamResponse(to: request.prompt, options: options))
        var content = ""
        var yields = 0

        while true {
            // Between snapshots: the deadline, the pod going away, and anyone
            // else waiting for the device are all noticed here.
            let heldBefore = job.timesYielded
            try job.yieldIfNeeded()
            yields += job.timesYielded - heldBefore

            // Each snapshot is bounded too. Without this a model that stalls
            // mid-generation would sit on the device until the request deadline
            // with nothing to notice it, since the loop only comes round when a
            // snapshot arrives.
            let remaining = job.remaining
            guard remaining > 0 else { throw SchedulerError.timedOut(0) }

            let snapshot: String?
            do {
                snapshot = try awaitResult {
                    try await withDeadline(seconds: remaining) { try await puller.next() }
                }
            } catch let error as SchedulerError {
                throw error
            } catch {
                throw GenerationError.failed("\(error)")
            }

            guard let snapshot else { break }
            content = snapshot
        }

        return GenerateResult(content: content,
                              seconds: Date().timeIntervalSince(start),
                              yields: yields)
    }
}

/// Runs `work`, giving up after `seconds`.
///
/// The losing child is cancelled, which the model's own task honours; what it
/// cannot do is claw back a computation already inside the framework, so this
/// bounds the *waiting*, not the work.
func withDeadline<T: Sendable>(
    seconds: TimeInterval,
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw SchedulerError.timedOut(seconds)
        }
        guard let first = try await group.next() else {
            throw SchedulerError.timedOut(seconds)
        }
        group.cancelAll()
        return first
    }
}
