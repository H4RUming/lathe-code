import Darwin
import Foundation
import LatheDomain
@testable import LatheEngineHost
import LatheProtocol
import LatheProviders
import LatheRuntime
import Testing

private struct HostFixture {
    let root: URL
    let paths: EnginePaths
    let workspace: URL
    init() throws {
        root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("lathe-host-tests-\(UUID())")
        paths = try EnginePaths(root: root.appendingPathComponent("state"))
        workspace = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }
    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: paths.socketPath).deletingLastPathComponent())
    }
    func host(modelClient: ModelClient = ModelClient(), runnerURL: URL = URL(fileURLWithPath: "/unused"),
              chunkDelay: Duration = .seconds(30)) -> EngineHost {
        EngineHost(paths: paths, runnerURL: runnerURL, credentials: MemoryCredentialStore(), modelClient: modelClient, chunkDelay: chunkDelay)
    }
}

private func withStartedHost<T>(_ host: EngineHost, _ operation: () async throws -> T) async throws -> T {
    do {
        try await host.start()
        let result = try await operation()
        await host.stop()
        return result
    } catch {
        await host.stop()
        throw error
    }
}

private func waitForHostCondition(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw LatheError.transport("Host test condition timed out") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

struct EngineHostTests {
    @Test func hostRunsInsideOwnerProcessAndNeverAttachesToAnotherOwner() async throws {
        let fixture = try HostFixture(); defer { fixture.cleanup() }
        let host = fixture.host()
        try await withStartedHost(host) {
            let client = EngineClient(paths: fixture.paths)
            let info = try await client.connect()
            #expect(info.processID == getpid())
            #expect(try await host.start().engineID == info.engineID)
            let other = fixture.host()
            do {
                try await other.start()
                Issue.record("A second host attached or acquired an existing owner's data root")
            } catch SocketTransportError.alreadyRunning { }
            await other.stop()
            #expect(try await client.connect().engineID == info.engineID)
            #expect(FileManager.default.fileExists(atPath: fixture.paths.socketPath))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.socketPath))
    }

    @Test func stopInterruptsActiveRunAndNewOwnerCanRecoverWithoutReplay() async throws {
        let fixture = try HostFixture(); defer { fixture.cleanup() }
        let host = fixture.host()
        let (sessionID, runID, originalID) = try await withStartedHost(host) {
            let client = EngineClient(paths: fixture.paths)
            let info = try await client.connect()
            let session = try await client.createSession(title: "owner lifetime", workspacePath: fixture.workspace.path)
            let run = try await client.submit(sessionID: session.id, prompt: "wait for owner stop")
            return (session.id, run.id, info.engineID)
        }
        let restarted = fixture.host()
        try await withStartedHost(restarted) {
            let client = EngineClient(paths: fixture.paths)
            #expect(try await client.connect().engineID != originalID)
            let session = try await client.session(id: sessionID)
            let run = try #require(session.runs.first(where: { $0.id == runID }))
            #expect(run.state == .interrupted)
            #expect(run.response.isEmpty)
            let events = try await client.events(after: 0, runID: runID)
            #expect(events.events.filter { $0.kind == .runInterrupted }.count == 1)
        }
    }

    @Test func concurrentStopWaitsForWorkerCleanupAndRetainsLeaseUntilItFinishes() async throws {
        let fixture = try HostFixture(); defer { fixture.cleanup() }
        let transport = HostCleanupTransport()
        let host = fixture.host(modelClient: ModelClient(transport: transport))
        do {
            try await host.start()
            let client = EngineClient(paths: fixture.paths)
            let session = try await client.createSession(title: "cleanup", workspacePath: fixture.workspace.path)
            let profile = ProviderProfile(name: "fixture", api: .openAIChat, baseURL: "https://fixture.invalid/v1", model: "fixture")
            _ = try await client.saveProviderProfile(profile)
            _ = try await client.submitConfigured(sessionID: session.id, prompt: "wait", configuration: .init(profile: profile, permissionMode: .requestApproval))
            try await waitForHostCondition { await transport.started }
            let first = Task { await host.stop() }
            try await waitForHostCondition { await transport.cleanupStarted }
            let second = Task { await host.stop() }
            #expect(!FileManager.default.fileExists(atPath: fixture.paths.socketPath))
            #expect(throws: SocketTransportError.self) { try EngineLease(paths: fixture.paths) }
            await #expect(throws: (any Error).self) { try await client.connect() }
            await #expect(throws: LatheError.self) { try await host.start() }
            #expect(await !transport.cleaned)
            await transport.allowCleanup()
            await first.value
            await second.value
            #expect(await transport.cleaned)
            // Acquiring the same lease proves both stop calls returned only
            // after cleanup and ownership release.
            let acquired = try EngineLease(paths: fixture.paths)
            withExtendedLifetime(acquired) {}
            await host.stop()
            try await host.waitUntilStopped()
        } catch {
            await transport.allowCleanup()
            await host.stop()
            throw error
        }
    }

    @Test func stopBeforeStartIsTerminalAndFailedStartupReleasesOnlyItsLease() async throws {
        let fixture = try HostFixture(); defer { fixture.cleanup() }
        let stopped = fixture.host()
        await stopped.stop()
        await stopped.stop()
        await #expect(throws: LatheError.self) { try await stopped.start() }
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.socketPath))
        let failing = fixture.host(chunkDelay: .milliseconds(-1))
        await #expect(throws: LatheError.self) { try await failing.start() }
        await failing.stop()
        let replacement = fixture.host()
        try await withStartedHost(replacement) {
            let info = try await EngineClient(paths: fixture.paths).connect()
            #expect(info.processID == getpid())
        }
    }

    @Test func closedAdmissionRejectsAllRPCsWithoutMutatingRuntime() async throws {
        let fixture = try HostFixture(); defer { fixture.cleanup() }
        let runtime = try EngineRuntime(databaseURL: fixture.paths.database, credentials: MemoryCredentialStore())
        let service = EngineService(runtime: runtime, info: .init(processID: getpid(), engineID: UUID()))
        await service.closeAdmission()
        for request in [RPCRequest(method: "handshake"), RPCRequest(method: "createSession", params: .init(title: "must not exist", workspacePath: fixture.workspace.path))] {
            let data = await service.handle(try WireCodec.encode(request))
            let response = try WireCodec.decode(RPCResponse.self, from: data)
            #expect(response.id == request.id)
            #expect(response.result == nil)
            #expect(response.error?.code == -32009)
        }
        await service.drain()
        #expect(try await runtime.listSessions().sessions.isEmpty)
        await runtime.shutdown()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LATHE_TEST_RUNNER"] != nil, "Set LATHE_TEST_RUNNER to verify host shutdown waits for its native runner."))
    func stopWaitsForApprovedNativeRunnerAndItsDurableCancellationReceipt() async throws {
        let runnerPath = try #require(ProcessInfo.processInfo.environment["LATHE_TEST_RUNNER"])
        let fixture = try HostFixture(); defer { fixture.cleanup() }
        let arguments: [String: Any] = ["executable": "/bin/sh", "arguments": ["-c", "(trap '' TERM; /bin/sleep 1; /usr/bin/touch survived) & printf ready > ready; wait"], "workingDirectory": ".", "timeoutSeconds": 10]
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        let event: [String: Any] = ["choices": [["index": 0, "delta": ["tool_calls": [["index": 0, "id": "host_command", "type": "function", "function": ["name": "run_command", "arguments": encoded]]]], "finish_reason": "tool_calls"]]]
        var wire = Data("data: ".utf8)
        wire.append(try JSONSerialization.data(withJSONObject: event))
        wire.append(Data("\n\ndata: [DONE]\n\n".utf8))
        let host = fixture.host(modelClient: ModelClient(transport: HostCommandTransport(wire: wire)), runnerURL: URL(fileURLWithPath: runnerPath))
        let invocationID = try await withStartedHost(host) {
            let client = EngineClient(paths: fixture.paths)
            let session = try await client.createSession(title: "runner shutdown", workspacePath: fixture.workspace.path)
            let profile = ProviderProfile(name: "fixture", api: .openAIChat, baseURL: "https://fixture.invalid/v1", model: "fixture")
            _ = try await client.saveProviderProfile(profile)
            let run = try await client.submitConfigured(sessionID: session.id, prompt: "run", configuration: .init(profile: profile, permissionMode: .requestApproval))
            try await waitForHostCondition { try await client.invocations(runID: run.id).first?.state == .pendingApproval }
            let invocation = try #require(try await client.invocations(runID: run.id).first)
            _ = try await client.decideApproval(invocationID: invocation.id, requestHash: invocation.requestHash, approved: true)
            try await waitForHostCondition { FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("ready").path) }
            return invocation.id
        }
        let receipt = fixture.paths.directory.appendingPathComponent("executions/\(invocationID)/execution/result.json")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
        #expect((object["result"] as? [String: Any])?["reason"] as? String == "cancelled")
        #expect(!FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("survived").path))
        try await Task.sleep(for: .milliseconds(600))
        #expect(!FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("survived").path))
    }
}

private actor HostCleanupTransport: HTTPStreamingTransport {
    var started = false
    var cleanupStarted = false
    var cleaned = false
    private var allow = false
    private var waiter: CheckedContinuation<Void, Never>?
    func allowCleanup() { allow = true; waiter?.resume(); waiter = nil }
    func stream(request: URLRequest, onBytes: @escaping @Sendable (Data) async throws -> Bool) async throws {
        started = true
        do { try await Task.sleep(for: .seconds(60)) }
        catch {
            cleanupStarted = true
            if !allow { await withCheckedContinuation { waiter = $0 } }
            cleaned = true
            throw error
        }
    }
}

private struct HostCommandTransport: HTTPStreamingTransport {
    let wire: Data
    func stream(request: URLRequest, onBytes: @escaping @Sendable (Data) async throws -> Bool) async throws { _ = try await onBytes(wire) }
}
