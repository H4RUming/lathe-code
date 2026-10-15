import Foundation

public enum ProviderAPI: String, Codable, CaseIterable, Sendable {
    case openAIResponses, openAIChat
}

/// Connection metadata only. Credentials live in a separate credential store.
public struct ProviderProfile: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var api: ProviderAPI
    public var baseURL: String
    public var model: String
    public var allowInsecureHTTP: Bool
    public var reasoningEffort: String?

    public init(id: UUID = UUID(), name: String, api: ProviderAPI, baseURL: String, model: String,
                allowInsecureHTTP: Bool = false, reasoningEffort: String? = nil) {
        self.id = id; self.name = name; self.api = api; self.baseURL = baseURL; self.model = model
        self.allowInsecureHTTP = allowInsecureHTTP; self.reasoningEffort = reasoningEffort
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 200,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model.utf8.count <= 200,
              !model.contains(where: { $0.isNewline || $0.asciiValue == 0 }), baseURL.utf8.count <= 4096,
              let components = URLComponents(string: baseURL), let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.port.map({ 1...65535 ~= $0 }) ?? true,
              components.url != nil else {
            throw LatheError.invalidRequest("모델 연결의 이름·모델·base URL을 확인하세요. URL에는 인증 정보나 query를 넣을 수 없습니다.")
        }
        guard components.scheme == "https" || (components.scheme == "http" && allowInsecureHTTP) else {
            throw LatheError.invalidRequest("HTTPS가 필요합니다. HTTP 서버는 해당 연결에서 명시적으로 허용하세요.")
        }
        guard !components.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw LatheError.invalidRequest("base URL에는 상대 경로를 사용할 수 없습니다.")
        }
        if let reasoningEffort {
            guard !reasoningEffort.isEmpty, reasoningEffort.utf8.count <= 40,
                  reasoningEffort.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
                throw LatheError.invalidRequest("유효하지 않은 reasoning effort입니다.")
            }
        }
    }
}

public struct ModelToolCall: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let arguments: String
    public init(id: String, name: String, arguments: String) {
        self.id = id; self.name = name; self.arguments = arguments
    }
}

public struct ToolDefinition: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let parametersJSON: String
    public init(name: String, description: String, parametersJSON: String) {
        self.name = name; self.description = description; self.parametersJSON = parametersJSON
    }
}
