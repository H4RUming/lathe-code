import Foundation
import LatheLocalization
import LatheDomain

/// GUI and CLI use this client; reconnecting never resubmits a prompt.
public actor EngineClient {
    public let paths: EnginePaths
    private let executableURL: URL?

    public init(paths: EnginePaths, executableURL: URL? = nil) {
        self.paths = paths; self.executableURL = executableURL
    }

    public func connect() async throws -> EngineInfo {
        if let executableURL {
            try await EngineBootstrap.ensureRunning(paths: paths, executableURL: executableURL)
        }
        let result: RPCResult
        do { result = try await call("handshake") }
        catch let error as RPCFailure where error.code == -32001 {
            let legacy = try? await call("handshake", params: .init(protocolVersion: 1))
            if let pid = legacy?.info?.processID {
                throw LatheError.transport(L10n.errorFormat("protocol.engine.incompatibleLegacyPID", table: "ProtocolErrors", String(pid)))
            }
            throw LatheError.transport(L10n.errorText("protocol.engine.incompatibleLegacy", table: "ProtocolErrors"))
        }
        guard let info = result.info else { throw malformedResponse() }
        guard info.protocolVersion == EngineProtocol.version else {
            throw LatheError.incompatibleVersion(info.protocolVersion)
        }
        return info
    }

    public func listSessions() async throws -> [SessionSnapshot] {
        var result: [SessionSnapshot] = []
        var cursor: UUID?
        repeat {
            let page = try await listSessionsPage(before: cursor)
            result.append(contentsOf: page.sessions)
            guard page.nextBefore != cursor || cursor == nil else { throw malformedResponse() }
            cursor = page.nextBefore
        } while cursor != nil
        return result
    }

    public func listSessionsPage(before: UUID? = nil, limit: Int = 50) async throws -> SessionPage {
        guard let page = try await call("sessions", params: .init(limit: limit, before: before)).sessions else { throw malformedResponse() }
        return page
    }

    public func session(id: UUID, beforeRunID: UUID? = nil, limit: Int = 4) async throws -> SessionSnapshot {
        guard let session = try await call("session", params: .init(sessionID: id, limit: limit, before: beforeRunID)).session else { throw malformedResponse() }
        return session
    }

    public func createSession(title: String, workspacePath: String) async throws -> SessionSnapshot {
        guard let session = try await call("createSession", params: .init(title: title, workspacePath: workspacePath)).session else { throw malformedResponse() }
        return session
    }

    public func submit(sessionID: UUID, prompt: String, requestID: UUID = UUID()) async throws -> RunSnapshot {
        try await submitConfigured(sessionID: sessionID, prompt: prompt, requestID: requestID, configuration: nil)
    }

    public func submitConfigured(sessionID: UUID, prompt: String, requestID: UUID = UUID(), configuration: RunConfiguration?) async throws -> RunSnapshot {
        guard let run = try await call("submit", params: .init(sessionID: sessionID, requestID: requestID, prompt: prompt, configuration: configuration)).run else { throw malformedResponse() }
        return run
    }

    public func providerProfiles() async throws -> [ProviderProfile] {
        guard let profiles = try await call("providerProfiles").profiles else { throw malformedResponse() }
        return profiles
    }

    public func saveProviderProfile(_ profile: ProviderProfile, apiKey: String? = nil, clearCredential: Bool = false) async throws -> [ProviderProfile] {
        guard let profiles = try await call("saveProviderProfile", params: .init(profile: profile, apiKey: apiKey, clearCredential: clearCredential)).profiles else { throw malformedResponse() }
        return profiles
    }

    public func invocations(runID: UUID) async throws -> [ToolInvocationSnapshot] {
        guard let items = try await call("invocations", params: .init(runID: runID)).invocations else { throw malformedResponse() }
        return items
    }

    public func invocation(id: UUID) async throws -> ToolInvocationSnapshot {
        guard let item = try await call("invocation", params: .init(invocationID: id)).invocation else { throw malformedResponse() }
        return item
    }

    public func decideApproval(invocationID: UUID, requestHash: String, approved: Bool) async throws -> ToolInvocationSnapshot {
        guard let item = try await call("decideApproval", params: .init(invocationID: invocationID, requestHash: requestHash, approved: approved)).invocation else { throw malformedResponse() }
        return item
    }

    public func cancel(runID: UUID) async throws -> RunSnapshot {
        guard let run = try await call("cancel", params: .init(runID: runID)).run else { throw malformedResponse() }
        return run
    }

    public func events(after cursor: Int64, sessionID: UUID? = nil, runID: UUID? = nil, limit: Int = 256) async throws -> EventPage {
        guard let page = try await call("events", params: .init(sessionID: sessionID, runID: runID, cursor: cursor, limit: limit)).page else { throw malformedResponse() }
        return page
    }

    private func call(_ method: String, params: RPCParameters = .init()) async throws -> RPCResult {
        try Task.checkCancellation()
        let request = RPCRequest(method: method, params: params)
        let bytes = try await SocketTransport.exchange(path: paths.socketPath, payload: WireCodec.encode(request))
        try Task.checkCancellation()
        let response = try WireCodec.decode(RPCResponse.self, from: bytes)
        guard response.jsonrpc == "2.0", response.id == request.id,
              (response.result == nil) != (response.error == nil) else { throw malformedResponse() }
        if let error = response.error { throw error }
        guard let result = response.result else { throw malformedResponse() }
        return result
    }

    private func malformedResponse() -> LatheError {
        .transport(L10n.errorText("protocol.response.malformed", table: "ProtocolErrors"))
    }
}
