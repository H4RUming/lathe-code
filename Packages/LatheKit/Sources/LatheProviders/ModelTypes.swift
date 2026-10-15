import Foundation
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
        case .invalidRequest(let detail): "모델 요청 오류: \(detail)"
        case .invalidStream(let detail): "모델 스트림 오류: \(detail)"
        case .httpStatus(let status): "모델 서버가 HTTP \(status)를 반환했습니다."
        case .responseLimit: "모델 응답이 안전한 수신 한도를 초과했습니다."
        case .incompleteStream: "모델 연결이 정상 완료 이벤트 전에 종료되었습니다. 미완성 도구 호출은 실행하지 않습니다."
        case .unsupportedContent: "이 어댑터는 아직 해당 서버 도구·미디어 출력 형식을 지원하지 않습니다."
        }
    }
}
