import Foundation
import LatheLocalization

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
            throw LatheError.invalidRequest(L10n.errorText("domain.profile.invalid", table: "DomainErrors"))
        }
        guard components.scheme == "https" || (components.scheme == "http" && allowInsecureHTTP) else {
            throw LatheError.invalidRequest(L10n.errorText("domain.profile.requiresHTTPS", table: "DomainErrors"))
        }
        guard !components.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw LatheError.invalidRequest(L10n.errorText("domain.profile.relativePath", table: "DomainErrors"))
        }
        if let reasoningEffort {
            guard !reasoningEffort.isEmpty, reasoningEffort.utf8.count <= 40,
                  reasoningEffort.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
                throw LatheError.invalidRequest(L10n.errorText("domain.profile.invalidReasoningEffort", table: "DomainErrors"))
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
