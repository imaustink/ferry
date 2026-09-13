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

/// Serializes generation the same way GPU work is serialized, and for the same
/// reason: one device, and timings that mean something. An actor rather than a
/// semaphore, because the model's API is async and a semaphore cannot be waited
/// on from an async context -- actor isolation is the serialization.
actor Generator {
    /// Reads no actor state -- it asks the OS -- so the connection threads can
    /// have it without hopping.
    nonisolated var status: ModelStatus {
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

    func generate(_ request: GenerateRequest) async throws -> GenerateResult {
        let status = self.status
        guard status.available else {
            throw GenerationError.unavailable(status.reason ?? "the on-device model is unavailable")
        }
        guard !request.prompt.isEmpty else { throw GenerationError.failed("prompt is required") }

        // A fresh session per request: pods do not share a conversation, and a
        // transcript that accumulated across tenants would be a leak, not a
        // feature.
        let session = request.instructions.map { LanguageModelSession(instructions: $0) }
            ?? LanguageModelSession()
        let options = GenerationOptions(temperature: request.temperature,
                                        maximumResponseTokens: request.maxTokens)

        let start = Date()
        do {
            let response = try await session.respond(to: request.prompt, options: options)
            return GenerateResult(content: response.content,
                                  seconds: Date().timeIntervalSince(start))
        } catch {
            throw GenerationError.failed("\(error)")
        }
    }
}
