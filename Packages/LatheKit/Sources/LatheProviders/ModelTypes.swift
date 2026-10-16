import Foundation
import LatheLocalization
import LatheDomain

public enum ModelMessage: Codable, Sendable, Equatable {
    case system(String), user(String), assistant(ModelStep), toolResult(callID: String, content: String)
}

public enum ModelStepOutcome: String, Codable, Sendable {
    case final, clientTools, blocked, truncated, noUsableOutput
}

/// Opaque adapter state; never turn this into user-visible text or send it to another connection.
public struct ModelContinuation: Codable, Sendable, Equatable {
    public let api: ProviderAPI
    public let baseURL: String
    public let model: String
    public let payload: Data
    public init(api: ProviderAPI, baseURL: String, model: String, payload: Data) {
        self.api = api; self.baseURL = baseURL; self.model = model; self.payload = payload
    }
}

public struct ModelStep: Codable, Sendable, Equatable {
    public let text: String
    public let calls: [ModelToolCall]
    public let outcome: ModelStepOutcome
    public let continuation: ModelContinuation?
    public init(text: String, calls: [ModelToolCall] = [], outcome: ModelStepOutcome, continuation: ModelContinuation? = nil) {
        self.text = text; self.calls = calls; self.outcome = outcome; self.continuation = continuation
    }
}

public enum ProviderError: Error, LocalizedError, Sendable, Equatable {
    case invalidRequest(String), invalidStream(String), httpStatus(Int), responseLimit, incompleteStream, unsupportedContent
    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let detail): L10n.format("provider.error.invalidRequest", table: "ProviderErrors", detail)
        case .invalidStream(let detail): L10n.format("provider.error.invalidStream", table: "ProviderErrors", detail)
        case .httpStatus(let status): L10n.format("provider.error.httpStatus", table: "ProviderErrors", String(status))
        case .responseLimit: L10n.text("provider.error.responseLimit", table: "ProviderErrors")
        case .incompleteStream: L10n.text("provider.error.incompleteStream", table: "ProviderErrors")
        case .unsupportedContent: L10n.text("provider.error.unsupportedContent", table: "ProviderErrors")
        }
    }
}
