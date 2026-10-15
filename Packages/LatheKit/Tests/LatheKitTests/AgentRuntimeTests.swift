import CSQLite
import CryptoKit
import Foundation
import LatheDomain
import LatheProviders
import LatheRuntime
import Testing

private actor CapturingTransport: HTTPStreamingTransport {
    private(set) var requests: [URLRequest] = []
    func stream(request: URLRequest, onBytes: @escaping @Sendable (Data) async throws -> Bool) async throws {
        requests.append(request)
        let frame = #"{"choices":[{"index":0,"delta":{"content":"fixture complete"},"finish_reason":"stop"}]}"#
        _ = try await onBytes(Data(("data: " + frame + "\n\ndata: [DONE]\n\n").utf8))
    }
}

private actor WaitingTransport: HTTPStreamingTransport {
    private(set) var started = false
    private(set) var cancelled = false
    func stream(request: URLRequest, onBytes: @escaping @Sendable (Data) async throws -> Bool) async throws {
        started = true
        do { try await Task.sleep(for: .seconds(30)) }
        catch { cancelled = Task.isCancelled; throw error }
    }
}

private actor WriteCallTransport: HTTPStreamingTransport {
    private(set) var requestCount = 0
    let expectedHash: String
    init(expectedHash: String) { self.expectedHash = expectedHash }
    func stream(request: URLRequest, onBytes: @escaping @Sendable (Data) async throws -> Bool) async throws {
        requestCount += 1
        let frame: String
        if requestCount == 1 {
            let arguments = try JSONSerialization.data(withJSONObject: ["path": "file.txt", "content": "agent edit", "expectedSHA256": expectedHash])
            let object: [String: Any] = ["choices": [["index": 0, "delta": ["tool_calls": [["index": 0,
                "id": "write-call", "type": "function", "function": ["name": "write_file", "arguments": String(decoding: arguments, as: UTF8.self)]]]],
                "finish_reason": "tool_calls"]]]
            frame = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        } else {
            frame = #"{"choices":[{"index":0,"delta":{"content":"unexpected continuation"},"finish_reason":"stop"}]}"#
        }
        _ = try await onBytes(Data(("data: " + frame + "\n\ndata: [DONE]\n\n").utf8))
    }
}

private struct AgentFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lathe-agent-runtime-\(UUID().uuidString)")
    var database: URL { root.appendingPathComponent("state/lathe.sqlite") }
    var workspace: URL { root.appendingPathComponent("workspace") }
    init() throws { try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func sql(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(database.path, &db) == SQLITE_OK else { throw LatheError.storage("fixture database") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw LatheError.storage("fixture SQL") }
    }
}

private func complete(_ runtime: EngineRuntime, sessionID: UUID, runID: UUID) async throws -> RunSnapshot {
    let deadline = ContinuousClock.now + .seconds(4)
    while ContinuousClock.now < deadline {
        let snapshot = try await runtime.session(id: sessionID)
        if let run = snapshot.runs.first(where: { $0.id == runID }), run.state != .running { return run }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw LatheError.transport("fixture completion timeout")
}

struct AgentRuntimeTests {
    @Test func retryUsesOriginalConfigurationAfterProfileUpdateAndRejectsChangedPayload() async throws {
        let fixture = try AgentFixture(); defer { fixture.cleanup() }
        let transport = CapturingTransport()
        let runtime = try EngineRuntime(databaseURL: fixture.database, credentials: MemoryCredentialStore(), modelClient: ModelClient(transport: transport))
        let profile = ProviderProfile(name: "fixture", api: .openAIChat, baseURL: "https://fixture.invalid/v1", model: "original")
        _ = try await runtime.saveProviderProfile(profile, apiKey: nil, clearCredential: false)
        let session = try await runtime.createSession(title: "retry", workspacePath: fixture.workspace.path)
        let requestID = UUID(), configuration = RunConfiguration(profile: profile)
        let run = try await runtime.submit(sessionID: session.id, prompt: "original prompt", requestID: requestID, configuration: configuration)
        #expect(try await complete(runtime, sessionID: session.id, runID: run.id).state == .completed)
        var changed = profile; changed.model = "updated"
        _ = try await runtime.saveProviderProfile(changed, apiKey: nil, clearCredential: false)
        let retry = try await runtime.submit(sessionID: session.id, prompt: "original prompt", requestID: requestID, configuration: configuration)
        #expect(retry.id == run.id)
        #expect(retry.configuration == configuration)
        await #expect(throws: LatheError.self) {
            try await runtime.submit(sessionID: session.id, prompt: "original prompt", requestID: requestID, configuration: .init(profile: changed))
        }
        await #expect(throws: LatheError.self) {
            try await runtime.submit(sessionID: session.id, prompt: "changed prompt", requestID: requestID, configuration: configuration)
        }
        await #expect(throws: LatheError.self) {
            try await runtime.submit(sessionID: session.id, prompt: "stale new request", requestID: UUID(), configuration: configuration)
        }
        #expect(await transport.requests.count == 1)
    }

    @Test func cancellationStopsWorkerEvenWhenItsDatabaseReceiptFails() async throws {
        let fixture = try AgentFixture(); defer { fixture.cleanup() }
        let transport = WaitingTransport()
        let runtime = try EngineRuntime(databaseURL: fixture.database, credentials: MemoryCredentialStore(), modelClient: ModelClient(transport: transport))
        let profile = ProviderProfile(name: "fixture", api: .openAIChat, baseURL: "https://fixture.invalid/v1", model: "fixture")
        _ = try await runtime.saveProviderProfile(profile, apiKey: nil, clearCredential: false)
        let session = try await runtime.createSession(title: "cancel failure", workspacePath: fixture.workspace.path)
        let run = try await runtime.submit(sessionID: session.id, prompt: "wait", requestID: UUID(), configuration: .init(profile: profile))
        let deadline = ContinuousClock.now + .seconds(4)
        while !(await transport.started) {
            guard ContinuousClock.now < deadline else { throw LatheError.transport("fixture start timeout") }
            try await Task.sleep(for: .milliseconds(5))
        }
        try fixture.sql("CREATE TRIGGER reject_cancel BEFORE UPDATE ON runs WHEN NEW.state = 'cancelled' BEGIN SELECT RAISE(ABORT, 'fixture cancellation receipt failure'); END")
        await #expect(throws: LatheError.self) { try await runtime.cancel(runID: run.id) }
        #expect(await transport.cancelled)
        // The receipt failure is still reported; a later successful receipt can
        // resolve the stored state without starting another model request.
        try fixture.sql("DROP TRIGGER reject_cancel")
        #expect(try await runtime.cancel(runID: run.id).state == .cancelled)
    }

    @Test func failedToolReceiptStopsLoopBeforeAnotherModelRequest() async throws {
        let fixture = try AgentFixture(); defer { fixture.cleanup() }
        let file = fixture.workspace.appendingPathComponent("file.txt")
        let original = Data("original".utf8)
        try original.write(to: file)
        let hash = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        let transport = WriteCallTransport(expectedHash: hash)
        let runtime = try EngineRuntime(databaseURL: fixture.database, credentials: MemoryCredentialStore(), modelClient: ModelClient(transport: transport))
        let profile = ProviderProfile(name: "fixture", api: .openAIChat, baseURL: "https://fixture.invalid/v1", model: "fixture")
        _ = try await runtime.saveProviderProfile(profile, apiKey: nil, clearCredential: false)
        let session = try await runtime.createSession(title: "receipt failure", workspacePath: fixture.workspace.path)
        let run = try await runtime.submit(sessionID: session.id, prompt: "edit", requestID: UUID(), configuration: .init(profile: profile, permissionMode: .manual))
        let deadline = ContinuousClock.now + .seconds(4)
        var pending: ToolInvocationSnapshot?
        while pending == nil {
            pending = try await runtime.invocations(runID: run.id).first { $0.state == .pendingApproval }
            guard ContinuousClock.now < deadline else { throw LatheError.transport("fixture approval timeout") }
            if pending == nil { try await Task.sleep(for: .milliseconds(5)) }
        }
        let invocation = try #require(pending)
        try Data("human edit".utf8).write(to: file)
        try fixture.sql("CREATE TRIGGER reject_failed_receipt BEFORE UPDATE ON tool_invocations WHEN NEW.state = 'failed' BEGIN SELECT RAISE(ABORT, 'fixture failed tool receipt'); END")
        _ = try await runtime.decideApproval(invocationID: invocation.id, requestHash: invocation.requestHash, approved: true)
        #expect(try await complete(runtime, sessionID: session.id, runID: run.id).state == .failed)
        #expect(await transport.requestCount == 1)
        #expect(try String(contentsOf: file, encoding: .utf8) == "human edit")
        #expect(try await runtime.invocation(id: invocation.id).state == .executing)
    }

    @Test func endpointChangeCannotReuseKeyAndFailedMetadataUpdateCannotRedirectIt() async throws {
        let fixture = try AgentFixture()
        defer { fixture.cleanup() }
        let transport = CapturingTransport()
        let runtime = try EngineRuntime(databaseURL: fixture.database, credentials: MemoryCredentialStore(), modelClient: ModelClient(transport: transport))
        let profile = ProviderProfile(name: "fixture", api: .openAIChat, baseURL: "https://first.invalid/v1", model: "fixture")
        _ = try await runtime.saveProviderProfile(profile, apiKey: "fixture-old-key", clearCredential: false)
        var changed = profile
        changed.baseURL = "https://second.invalid/v1"
        do {
            _ = try await runtime.saveProviderProfile(changed, apiKey: nil, clearCredential: false)
            Issue.record("Endpoint change reused an existing credential without explicit action")
        } catch LatheError.invalidRequest { }
        try fixture.sql("CREATE TRIGGER fail_profile BEFORE UPDATE ON provider_profiles BEGIN SELECT RAISE(ABORT, 'fixture failure'); END")
        do {
            _ = try await runtime.saveProviderProfile(changed, apiKey: "fixture-new-key", clearCredential: false)
            Issue.record("Injected metadata failure did not reject the update")
        } catch LatheError.storage { }
        #expect(try await runtime.providerProfiles() == [profile])
        let session = try await runtime.createSession(title: "credential binding", workspacePath: fixture.workspace.path)
        let run = try await runtime.submit(sessionID: session.id, prompt: "fixture", requestID: UUID(), configuration: .init(profile: profile))
        let done = try await complete(runtime, sessionID: session.id, runID: run.id)
        #expect(done.state == .completed)
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests.first?.url?.host == "first.invalid")
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-old-key")
        let encoded = try JSONEncoder().encode(done)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("fixture-old-key"))
    }

    @Test func completedContextIsRestoredButConnectionChangeStartsFresh() async throws {
        let fixture = try AgentFixture()
        defer { fixture.cleanup() }
        let transport = CapturingTransport()
        let runtime = try EngineRuntime(databaseURL: fixture.database, credentials: MemoryCredentialStore(), modelClient: ModelClient(transport: transport))
        let profile = ProviderProfile(name: "fixture", api: .openAIChat, baseURL: "https://fixture.invalid/v1", model: "fixture")
        _ = try await runtime.saveProviderProfile(profile, apiKey: nil, clearCredential: false)
        let session = try await runtime.createSession(title: "context", workspacePath: fixture.workspace.path)
        for prompt in ["first prompt", "second prompt"] {
            let run = try await runtime.submit(sessionID: session.id, prompt: prompt, requestID: UUID(), configuration: .init(profile: profile))
            #expect(try await complete(runtime, sessionID: session.id, runID: run.id).state == .completed)
        }
        var changed = profile
        changed.model = "another-fixture"
        _ = try await runtime.saveProviderProfile(changed, apiKey: nil, clearCredential: false)
        let third = try await runtime.submit(sessionID: session.id, prompt: "third prompt", requestID: UUID(), configuration: .init(profile: changed))
        #expect(try await complete(runtime, sessionID: session.id, runID: third.id).state == .completed)
        let requests = await transport.requests
        let secondData = try #require(requests[1].httpBody)
        let thirdData = try #require(requests[2].httpBody)
        let second = try #require(JSONSerialization.jsonObject(with: secondData) as? [String: Any])
        let thirdBody = try #require(JSONSerialization.jsonObject(with: thirdData) as? [String: Any])
        let secondMessages = try #require(second["messages"] as? [[String: Any]])
        let thirdMessages = try #require(thirdBody["messages"] as? [[String: Any]])
        #expect(secondMessages.count == 4)
        #expect(secondMessages[1]["content"] as? String == "first prompt")
        #expect(thirdMessages.count == 2)
        #expect(thirdMessages[1]["content"] as? String == "third prompt")
    }
}
