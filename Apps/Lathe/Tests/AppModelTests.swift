import Foundation
import LatheDomain
import LatheProtocol
import Testing
@testable import LatheAppSupport

@MainActor
struct AppModelTests {
    @Test func snapshotFailureDoesNotCommitEventCursor() async throws {
        let engine = FixtureEngine()
        let model = LatheAppModel(client: engine)
        await model.connect()
        await engine.publishCompletionAndFailSnapshot()
        try await waitUntil { !model.isConnected }
        #expect(model.errorMessage != nil)
        #expect(await engine.observedCursors.allSatisfy { $0 == 0 })

        await model.connect()
        try await waitUntil { await engine.observedCursors.contains(1) }
        #expect(model.isConnected)
        #expect(model.selectedSession?.runs.last?.state == .completed)
        #expect(await engine.submissionCount == 0)
    }

    @Test func promptLimitUsesUTF8Bytes() async {
        let engine = FixtureEngine()
        let model = LatheAppModel(client: engine)
        await model.connect()
        model.draft = String(repeating: "a", count: 32_768)
        #expect(model.canSubmit)
        model.draft.append("a")
        #expect(!model.canSubmit)
        model.draft = String(repeating: "한", count: 11_000)
        #expect(model.draftByteCount == 33_000)
        #expect(model.isDraftOverLimit)
        model.sendPrompt()
        #expect(await engine.submissionCount == 0)
        #expect(model.isConnected)
    }

    @Test(arguments: [-32602, -32009])
    func definiteRejectionPreservesConnectionAndDraft(code: Int) async throws {
        let engine = FixtureEngine()
        await engine.rejectSubmission(code: code)
        let model = LatheAppModel(client: engine)
        await model.connect()
        model.draft = "수정할 요청"
        model.sendPrompt()
        try await waitUntil { !model.isSubmitting }
        #expect(model.isConnected)
        #expect(model.draft == "수정할 요청")
        #expect(model.errorMessage?.contains("거절") == true)
        let calls = await engine.eventQueryCount
        try await waitUntil { await engine.eventQueryCount > calls }
    }

    @Test func unknownSubmissionOutcomeStopsPolling() async throws {
        let engine = FixtureEngine()
        await engine.failTransportOnSubmission()
        let model = LatheAppModel(client: engine)
        await model.connect()
        model.draft = "결과를 알 수 없는 요청"
        model.sendPrompt()
        try await waitUntil { !model.isSubmitting }
        #expect(!model.isConnected)
        #expect(model.draft == "결과를 알 수 없는 요청")
        #expect(model.errorMessage?.contains("결과를 확인하지 못했습니다") == true)
    }

    @Test func delayedSubmissionPreservesNewDraftInAnotherSession() async throws {
        let engine = FixtureEngine()
        await engine.holdSubmission()
        let model = LatheAppModel(client: engine)
        await model.connect()
        model.draft = "보낸 초안"
        model.sendPrompt()
        try await waitUntil { await engine.submissionCount == 1 }
        model.draft = "전송 뒤에 작성한 새 초안"
        model.selectSession(engine.secondID)
        await engine.releaseSubmission()
        try await waitUntil { !model.isSubmitting }
        model.selectSession(engine.firstID)
        #expect(model.draft == "전송 뒤에 작성한 새 초안")
    }

    @Test func windowCancellationDoesNotCancelSharedConnection() async throws {
        let engine = FixtureEngine()
        await engine.holdConnection()
        let model = LatheAppModel(client: engine)
        let firstWindow = Task { await model.ensureConnected() }
        try await waitUntil { await engine.connectionCount == 1 }
        let secondWindow = Task { await model.ensureConnected() }
        firstWindow.cancel()
        await engine.releaseConnection()
        await secondWindow.value
        #expect(model.isConnected)
        await model.ensureConnected()
        #expect(await engine.connectionCount == 1)
    }

    @Test func realSubmissionFreezesConnectionAndPermissionBeforeAsyncWork() async throws {
        let engine = FixtureEngine()
        await engine.holdSubmission()
        let model = LatheAppModel(client: engine)
        await model.connect()
        model.selectedProfileID = engine.profile.id
        model.permissionMode = .acceptEdits
        model.draft = "real fixture request"
        model.sendPrompt()
        // Settings changing while the submit task starts must not change its payload.
        model.selectedProfileID = nil
        model.permissionMode = .plan
        try await waitUntil { await engine.submissionCount == 1 }
        #expect(await engine.submittedConfiguration?.profile == engine.profile)
        #expect(await engine.submittedConfiguration?.permissionMode == .acceptEdits)
        await engine.releaseSubmission()
        try await waitUntil { !model.isSubmitting }
        #expect(model.draft.isEmpty)
    }

    @Test func approvalUsesDisplayedHashAndIgnoresLateResultAfterSessionChange() async throws {
        let engine = FixtureEngine()
        let invocation = await engine.seedApproval()
        await engine.holdApproval()
        let model = LatheAppModel(client: engine)
        await model.connect()
        #expect(model.toolInvocations[invocation.runID]?.first == invocation)
        model.decideApproval(invocation, approved: true)
        try await waitUntil { await engine.approvalCount == 1 }
        #expect(await engine.approvalHash == invocation.requestHash)
        model.selectSession(engine.secondID)
        await engine.releaseApproval()
        try await waitUntil { model.decidingApprovals.isEmpty && model.selectedSession?.id == engine.secondID }
        #expect(model.toolInvocations[invocation.runID] == nil)
        model.decideApproval(invocation, approved: true)
        #expect(await engine.approvalCount == 1)
        #expect(model.errorMessage == nil)
    }

    @Test func savingConnectionDuringRunDoesNotReplaceItsFrozenProfile() async throws {
        let engine = FixtureEngine()
        let invocation = await engine.seedApproval()
        let model = LatheAppModel(client: engine)
        await model.connect()
        model.selectedProfileID = engine.profile.id
        var updated = engine.profile
        updated.model = "new-fixture-model"
        #expect(await model.saveProfile(updated, apiKey: nil, clearCredential: false))
        #expect(model.profiles == [updated])
        #expect(model.selectedSession?.activeRun?.configuration?.profile == engine.profile)
        #expect(model.toolInvocations[invocation.runID]?.first == invocation)
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CheckFailure.timedOut
    }
}

private enum CheckFailure: Error { case timedOut }

private actor FixtureEngine: AppEngineClient {
    nonisolated let firstID = UUID()
    nonisolated let secondID = UUID()
    nonisolated let profile = ProviderProfile(name: "Fixture", api: .openAIChat, baseURL: "https://model.example.test/v1", model: "fixture-model")
    private var savedProfile: ProviderProfile?
    private var tool: ToolInvocationSnapshot?
    private var holdsApproval = false
    private var approvalGate: CheckedContinuation<Void, Never>?
    private(set) var submittedConfiguration: RunConfiguration?
    private(set) var approvalCount = 0
    private(set) var approvalHash: String?
    private var completedRun: RunSnapshot?
    private var failSnapshot = false
    private var hasEvent = false
    private var submissionFailure: RPCFailure?
    private var transportFailure = false
    private var holdsSubmission = false
    private var submissionGate: CheckedContinuation<Void, Never>?
    private var holdsConnection = false
    private var connectionGate: CheckedContinuation<Void, Never>?
    private(set) var observedCursors: [Int64] = []
    private(set) var submissionCount = 0
    private(set) var connectionCount = 0
    var eventQueryCount: Int { observedCursors.count }

    func connect() async throws -> EngineInfo {
        connectionCount += 1
        if holdsConnection { await withCheckedContinuation { connectionGate = $0 } }
        try Task.checkCancellation()
        return EngineInfo(processID: 1, engineID: firstID)
    }

    func listSessions() async throws -> [SessionSnapshot] {
        [snapshot(id: firstID), snapshot(id: secondID)]
    }

    func session(id: UUID, beforeRunID: UUID?, limit: Int) async throws -> SessionSnapshot {
        if failSnapshot {
            failSnapshot = false
            throw RPCFailure(code: -32603, message: "injected snapshot read failure")
        }
        return snapshot(id: id)
    }

    func createSession(title: String, workspacePath: String) async throws -> SessionSnapshot {
        SessionSnapshot(title: title, workspacePath: workspacePath)
    }

    func submit(sessionID: UUID, prompt: String, requestID: UUID) async throws -> RunSnapshot {
        submissionCount += 1
        if let submissionFailure { throw submissionFailure }
        if transportFailure { throw LatheError.transport("injected connection loss") }
        if holdsSubmission { await withCheckedContinuation { submissionGate = $0 } }
        return RunSnapshot(sessionID: sessionID, prompt: prompt, response: "done", state: .completed)
    }

    func providerProfiles() async throws -> [ProviderProfile] { [savedProfile ?? profile] }
    func saveProviderProfile(_ profile: ProviderProfile, apiKey: String?, clearCredential: Bool) async throws -> [ProviderProfile] {
        savedProfile = profile
        return [profile]
    }
    func submitConfigured(sessionID: UUID, prompt: String, requestID: UUID, configuration: RunConfiguration?) async throws -> RunSnapshot {
        submittedConfiguration = configuration
        return try await submit(sessionID: sessionID, prompt: prompt, requestID: requestID)
    }
    func invocations(runID: UUID) async throws -> [ToolInvocationSnapshot] {
        guard let tool, tool.runID == runID else { return [] }
        return [tool]
    }
    func decideApproval(invocationID: UUID, requestHash: String, approved: Bool) async throws -> ToolInvocationSnapshot {
        approvalCount += 1
        approvalHash = requestHash
        if holdsApproval { await withCheckedContinuation { approvalGate = $0 } }
        guard var snapshot = tool, snapshot.id == invocationID else { throw LatheError.notFound("fixture approval missing") }
        snapshot.state = approved ? .approved : .denied
        tool = snapshot
        return snapshot
    }
    func seedApproval() -> ToolInvocationSnapshot {
        let run = RunSnapshot(sessionID: firstID, prompt: "fixture approval", configuration: RunConfiguration(profile: profile))
        completedRun = run
        let snapshot = ToolInvocationSnapshot(runID: run.id, callID: "fixture-call", name: "write_file", arguments: "{}", requestHash: String(repeating: "a", count: 64), summary: "Write fixture", effect: .write, state: .pendingApproval)
        tool = snapshot
        return snapshot
    }
    func holdApproval() { holdsApproval = true }
    func releaseApproval() { holdsApproval = false; approvalGate?.resume(); approvalGate = nil }

    func cancel(runID: UUID) async throws -> RunSnapshot {
        RunSnapshot(id: runID, sessionID: firstID, prompt: "", state: .cancelled)
    }

    func events(after: Int64, sessionID: UUID?, runID: UUID?, limit: Int) async throws -> EventPage {
        observedCursors.append(after)
        guard hasEvent, after < 1 else { return EventPage(events: [], nextCursor: after) }
        let event = EngineEvent(sequence: 1, sessionID: firstID, kind: .runCompleted)
        return EventPage(events: [event], nextCursor: 1)
    }

    func publishCompletionAndFailSnapshot() {
        completedRun = RunSnapshot(sessionID: firstID, prompt: "done", response: "completed", state: .completed)
        failSnapshot = true
        hasEvent = true
    }
    func rejectSubmission(code: Int) { submissionFailure = RPCFailure(code: code, message: "request rejected") }
    func failTransportOnSubmission() { transportFailure = true }
    func holdSubmission() { holdsSubmission = true }
    func releaseSubmission() { holdsSubmission = false; submissionGate?.resume(); submissionGate = nil }
    func holdConnection() { holdsConnection = true }
    func releaseConnection() { holdsConnection = false; connectionGate?.resume(); connectionGate = nil }

    private func snapshot(id: UUID) -> SessionSnapshot {
        SessionSnapshot(id: id, title: id == firstID ? "First" : "Second", workspacePath: "/tmp", runs: id == firstID ? completedRun.map { [$0] } ?? [] : [])
    }
}
