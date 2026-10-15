import Foundation
import LatheDomain

public enum EngineProtocol {
    public static let version = 2
    public static let maximumFrameBytes = 1_048_576
}

public struct RPCParameters: Codable, Sendable {
    public let protocolVersion: Int
    public let sessionID: UUID?
    public let runID: UUID?
    public let requestID: UUID?
    public let title: String?
    public let workspacePath: String?
    public let prompt: String?
    public let cursor: Int64?
    public let limit: Int?
    public let before: UUID?
    public let configuration: RunConfiguration?
    public let profile: ProviderProfile?
    public let apiKey: String?
    public let clearCredential: Bool?
    public let invocationID: UUID?
    public let requestHash: String?
    public let approved: Bool?

    public init(protocolVersion: Int = EngineProtocol.version, sessionID: UUID? = nil, runID: UUID? = nil, requestID: UUID? = nil, title: String? = nil, workspacePath: String? = nil, prompt: String? = nil, cursor: Int64? = nil, limit: Int? = nil, before: UUID? = nil, configuration: RunConfiguration? = nil, profile: ProviderProfile? = nil, apiKey: String? = nil, clearCredential: Bool? = nil, invocationID: UUID? = nil, requestHash: String? = nil, approved: Bool? = nil) {
        self.protocolVersion = protocolVersion; self.sessionID = sessionID; self.runID = runID
        self.requestID = requestID; self.title = title; self.workspacePath = workspacePath
        self.prompt = prompt; self.cursor = cursor; self.limit = limit
        self.before = before
        self.configuration = configuration; self.profile = profile; self.apiKey = apiKey
        self.clearCredential = clearCredential; self.invocationID = invocationID
        self.requestHash = requestHash; self.approved = approved
    }
}

public struct RPCRequest: Codable, Sendable {
    public let jsonrpc: String
    public let id: String
    public let method: String
    public let params: RPCParameters

    public init(id: String = UUID().uuidString, method: String, params: RPCParameters = .init(), jsonrpc: String = "2.0") {
        self.jsonrpc = jsonrpc; self.id = id; self.method = method; self.params = params
    }
}

public struct RPCResult: Codable, Sendable {
    public let info: EngineInfo?
    public let session: SessionSnapshot?
    public let sessions: SessionPage?
    public let run: RunSnapshot?
    public let page: EventPage?
    public let profiles: [ProviderProfile]?
    public let invocations: [ToolInvocationSnapshot]?
    public let invocation: ToolInvocationSnapshot?

    public init(info: EngineInfo? = nil, session: SessionSnapshot? = nil, sessions: SessionPage? = nil, run: RunSnapshot? = nil, page: EventPage? = nil, profiles: [ProviderProfile]? = nil, invocations: [ToolInvocationSnapshot]? = nil, invocation: ToolInvocationSnapshot? = nil) {
        self.info = info; self.session = session; self.sessions = sessions; self.run = run; self.page = page
        self.profiles = profiles; self.invocations = invocations; self.invocation = invocation
    }
}

public struct RPCFailure: Codable, Error, LocalizedError, Sendable {
    public let code: Int
    public let message: String
    public var errorDescription: String? { message }
    public init(code: Int, message: String) { self.code = code; self.message = message }
}

public struct RPCResponse: Codable, Sendable {
    public let jsonrpc: String
    public let id: String?
    public let result: RPCResult?
    public let error: RPCFailure?

    public init(id: String?, result: RPCResult? = nil, error: RPCFailure? = nil) {
        jsonrpc = "2.0"; self.id = id; self.result = result; self.error = error
    }
}

public enum WireCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
}
