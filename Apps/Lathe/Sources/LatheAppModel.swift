import AppKit
import Combine
import Foundation
import LatheDomain
import LatheEngineHost
import LatheLocalization
import LatheProtocol

protocol AppEngineHost: Sendable {
    func start() async throws -> EngineInfo
    func stop() async
}

extension EngineHost: AppEngineHost {}

protocol AppEngineClient: Sendable {
    func connect() async throws -> EngineInfo
    func listSessions() async throws -> [SessionSnapshot]
    func session(id: UUID, beforeRunID: UUID?, limit: Int) async throws -> SessionSnapshot
    func createSession(title: String, workspacePath: String) async throws -> SessionSnapshot
    func submit(sessionID: UUID, prompt: String, requestID: UUID) async throws -> RunSnapshot
    func submitConfigured(sessionID: UUID, prompt: String, requestID: UUID, configuration: RunConfiguration?) async throws -> RunSnapshot
    func providerProfiles() async throws -> [ProviderProfile]
    func saveProviderProfile(_ profile: ProviderProfile, apiKey: String?, clearCredential: Bool) async throws -> [ProviderProfile]
    func invocations(runID: UUID) async throws -> [ToolInvocationSnapshot]
    func decideApproval(invocationID: UUID, requestHash: String, approved: Bool) async throws -> ToolInvocationSnapshot
    func cancel(runID: UUID) async throws -> RunSnapshot
    func events(after: Int64, sessionID: UUID?, runID: UUID?, limit: Int) async throws -> EventPage
}

extension AppEngineClient {
    func providerProfiles() async throws -> [ProviderProfile] { [] }
    func invocations(runID: UUID) async throws -> [ToolInvocationSnapshot] { [] }
    func submitConfigured(sessionID: UUID, prompt: String, requestID: UUID, configuration: RunConfiguration?) async throws -> RunSnapshot {
        guard configuration?.profile == nil else { throw LatheError.invalidRequest(L10n.errorText("app.error.realModelUnsupported", table: "AppMessages")) }
        return try await submit(sessionID: sessionID, prompt: prompt, requestID: requestID)
    }
    func saveProviderProfile(_ profile: ProviderProfile, apiKey: String?, clearCredential: Bool) async throws -> [ProviderProfile] {
        throw LatheError.invalidRequest(L10n.errorText("app.error.providerSaveUnavailable", table: "AppMessages"))
    }
    func decideApproval(invocationID: UUID, requestHash: String, approved: Bool) async throws -> ToolInvocationSnapshot {
        throw LatheError.invalidRequest(L10n.errorText("app.error.approvalUnavailable", table: "AppMessages"))
    }
}

extension EngineClient: AppEngineClient {}

@MainActor
final class LatheAppModel: ObservableObject {
    static let promptByteLimit = 32 * 1_024
    @Published private(set) var sessions: [SessionSnapshot] = []
    @Published private(set) var selectedSessionID: UUID?
    @Published private(set) var selectedSession: SessionSnapshot?
    @Published private(set) var engineInfo: EngineInfo?
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var isCreatingSession = false
    @Published private(set) var isSubmitting = false
    @Published private(set) var isCancelling = false
    @Published private(set) var isLoadingEarlier = false
    @Published private(set) var earlierCursor: UUID?
    @Published private(set) var profiles: [ProviderProfile] = []
    @Published var selectedProfileID: UUID?
    @Published var permissionMode: PermissionMode = .requestApproval
    @Published private(set) var toolInvocations: [UUID: [ToolInvocationSnapshot]] = [:]
    @Published private(set) var decidingApprovals: Set<UUID> = []
    @Published private(set) var isSavingProfile = false
    @Published private(set) var isExitDecisionPending = false
    @Published private(set) var isShuttingDown = false
    @Published var draft = ""
    @Published var errorMessage: String?

    private var client: (any AppEngineClient)?
    private var host: (any AppEngineHost)?
    private var hostStarted = false
    private var shutdownTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var connectionGeneration: UInt64 = 0
    private var selectionGeneration: UInt64 = 0
    private var cursor: Int64 = 0
    private var drafts: [UUID: String] = [:]
    private(set) var dataDirectory: URL?

    init(client: (any AppEngineClient)? = nil, host: (any AppEngineHost)? = nil) {
        self.client = client
        self.host = host
    }

    var selectedProfile: ProviderProfile? { profiles.first { $0.id == selectedProfileID } }
    var acceptsUserActions: Bool { !isExitDecisionPending && !isShuttingDown }
    var hasUnsentDrafts: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || drafts.contains { $0.key != selectedSessionID && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    var hasUnfinishedWork: Bool {
        hasUnsentDrafts || isSubmitting || isCreatingSession || isSavingProfile || isCancelling || !decidingApprovals.isEmpty
            || selectedSession?.activeRunID != nil || sessions.contains { $0.activeRunID != nil }
    }
    var canChangeRunConfiguration: Bool { acceptsUserActions && selectedSession?.activeRun == nil && !isSubmitting }

    var draftByteCount: Int { draft.utf8.count }
    var isDraftOverLimit: Bool { draftByteCount > Self.promptByteLimit }

    var canSubmit: Bool {
        acceptsUserActions && isConnected && selectedSession != nil && selectedSession?.activeRun == nil
            && (selectedProfileID == nil || selectedProfile != nil)
            && !isSubmitting && !isDraftOverLimit && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var connectionLabel: String {
        if isShuttingDown { return L10n.text("app.connection.shuttingDown", table: "AppMessages") }
        if isConnecting { return L10n.text("app.connection.connecting", table: "AppMessages") }
        return isConnected ? L10n.text("app.connection.connected", table: "AppMessages") : L10n.text("app.connection.disconnected", table: "AppMessages")
    }

    func ensureConnected() async {
        guard acceptsUserActions, !isConnected else { return }
        await connect()
    }

    func connect() async {
        guard acceptsUserActions else { return }
        if let connectionTask { await connectionTask.value; return }
        // Window .task cancellation must not cancel the connection shared by other windows.
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performConnect()
        }
        connectionTask = task
        await task.value
    }

    private func performConnect() async {
        guard acceptsUserActions, !Task.isCancelled else { return }
        isConnecting = true
        isConnected = false
        errorMessage = nil
        pollTask?.cancel()
        connectionGeneration &+= 1
        let generation = connectionGeneration
        defer {
            if generation == connectionGeneration { isConnecting = false }
            connectionTask = nil
        }
        do {
            if client == nil {
                let override = ProcessInfo.processInfo.environment["LATHE_DATA_DIR"]
                    .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
                let paths = try EnginePaths(root: override)
                dataDirectory = paths.directory
                let runner = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/lathe-runner")
                host = EngineHost(paths: paths, runnerURL: runner)
                client = EngineClient(paths: paths)
            }
            var ownedInfo: EngineInfo?
            if let host {
                ownedInfo = try await host.start()
                guard !isShuttingDown, generation == connectionGeneration, !Task.isCancelled else {
                    await host.stop()
                    return
                }
                hostStarted = true
            }
            guard let client else { return }
            let info = try await client.connect()
            if let ownedInfo {
                guard info.engineID == ownedInfo.engineID, info.processID == ownedInfo.processID else {
                    throw LatheError.transport(L10n.errorText("app.error.engineIdentityMismatch", table: "AppMessages"))
                }
            }
            let latest = try await client.listSessions()
            let latestProfiles = try await client.providerProfiles()
            guard !isShuttingDown, generation == connectionGeneration, !Task.isCancelled else { return }
            engineInfo = info
            sessions = latest
            profiles = latestProfiles
            isConnected = true
            if let selectedSessionID, latest.contains(where: { $0.id == selectedSessionID }) {
                try await refreshSelectedSession(using: client)
            } else if let first = latest.first {
                prepareSelection(first.id)
                try await refreshSelectedSession(using: client)
            } else {
                prepareSelection(nil)
            }
            guard isConnected, generation == connectionGeneration else { return }
            startPolling(using: client, generation: generation)
        } catch {
            guard generation == connectionGeneration else { return }
            isConnected = false
            errorMessage = L10n.errorFormat("app.error.connectionFailed", table: "AppMessages", error.localizedDescription)
        }
    }

    func selectSession(_ id: UUID?) {
        guard !isShuttingDown else { return }
        prepareSelection(id)
        guard let client, id != nil else { return }
        let generation = selectionGeneration
        Task {
            do { try await refreshSelectedSession(using: client) }
            catch {
                guard generation == selectionGeneration else { return }
                disconnectAfterFailure("app.error.sessionReadFailed", error: error)
            }
        }
    }

    private func prepareSelection(_ id: UUID?) {
        if let selectedSessionID { drafts[selectedSessionID] = draft }
        selectionGeneration &+= 1
        selectedSessionID = id
        selectedSession = nil
        toolInvocations = [:]
        earlierCursor = nil
        isLoadingEarlier = false
        draft = id.flatMap { drafts[$0] } ?? ""
    }

    func chooseProject() {
        guard acceptsUserActions else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text("app.projectPicker.title", table: "AppMessages")
        panel.prompt = L10n.text("app.projectPicker.open", table: "AppMessages")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let directory = panel.url else { return }
            Task { @MainActor [weak self] in await self?.createSession(in: directory) }
        }
    }

    func newSession() {
        guard acceptsUserActions else { return }
        guard let selectedSession else { chooseProject(); return }
        let directory = URL(fileURLWithPath: selectedSession.workspacePath, isDirectory: true)
        Task { await createSession(in: directory) }
    }

    func sendPrompt() {
        guard canSubmit, let client, let sessionID = selectedSessionID else { return }
        let prompt = draft
        let requestID = UUID()
        let configuration = selectedProfile.map { RunConfiguration(profile: $0, permissionMode: permissionMode) }
        isSubmitting = true
        errorMessage = nil
        Task {
            defer { isSubmitting = false }
            guard !isShuttingDown else { return }
            do {
                if let configuration {
                    _ = try await client.submitConfigured(sessionID: sessionID, prompt: prompt, requestID: requestID, configuration: configuration)
                } else {
                    _ = try await client.submit(sessionID: sessionID, prompt: prompt, requestID: requestID)
                }
            } catch {
                guard !isShuttingDown else { return }
                if let failure = error as? RPCFailure,
                   [-32600, -32601, -32602, -32004, -32009].contains(failure.code) {
                    errorMessage = L10n.errorFormat("app.error.submissionRejected", table: "AppMessages", failure.localizedDescription)
                } else {
                    disconnectAfterFailure("app.error.submissionOutcomeUnknown", error: error)
                }
                return
            }
            guard !isShuttingDown else { return }
            if drafts[sessionID] == prompt { drafts[sessionID] = "" }
            if selectedSessionID == sessionID, draft == prompt { draft = "" }
            do {
                try await refreshSessions(using: client)
                try await refreshSelectedSession(using: client)
            } catch {
                disconnectAfterFailure("app.error.submissionAcceptedStatusUnavailable", error: error)
            }
        }
    }

    func loadEarlierRuns() {
        guard !isShuttingDown, let client, let id = selectedSessionID, let before = earlierCursor, !isLoadingEarlier else { return }
        let generation = selectionGeneration
        isLoadingEarlier = true
        Task {
            defer { if generation == selectionGeneration { isLoadingEarlier = false } }
            do {
                let page = try await client.session(id: id, beforeRunID: before, limit: 4)
                guard generation == selectionGeneration, var current = selectedSession else { return }
                current.runs = mergedRuns(older: page.runs, newer: current.runs)
                selectedSession = current
                earlierCursor = page.nextBeforeRunID
                try await refreshTools(for: page.runs, using: client, generation: generation)
            } catch {
                guard generation == selectionGeneration else { return }
                errorMessage = L10n.errorFormat("app.error.earlierRunsReadFailed", table: "AppMessages", error.localizedDescription)
            }
        }
    }

    func stopRun() {
        guard acceptsUserActions, let client, let run = selectedSession?.activeRun, !isCancelling else { return }
        isCancelling = true
        Task {
            defer { isCancelling = false }
            do {
                _ = try await client.cancel(runID: run.id)
                try await refreshSelectedSession(using: client)
            } catch {
                errorMessage = L10n.errorFormat("app.error.cancellationStatusUnavailable", table: "AppMessages", error.localizedDescription)
            }
        }
    }

    private func createSession(in directory: URL) async {
        guard acceptsUserActions, let client, isConnected, !isCreatingSession else { return }
        isCreatingSession = true
        errorMessage = nil
        defer { isCreatingSession = false }
        do {
            let session = try await client.createSession(title: directory.lastPathComponent, workspacePath: directory.path)
            try await refreshSessions(using: client)
            selectSession(session.id)
        } catch {
            errorMessage = L10n.errorFormat("app.error.sessionCreationFailed", table: "AppMessages", error.localizedDescription)
        }
    }

    private func refreshSessions(using client: any AppEngineClient) async throws {
        let latest = try await client.listSessions()
        guard !isShuttingDown else { return }
        sessions = latest
    }

    private func refreshSelectedSession(using client: any AppEngineClient) async throws {
        guard let id = selectedSessionID else { return }
        let generation = selectionGeneration
        do {
            var snapshot = try await client.session(id: id, beforeRunID: nil, limit: 4)
            guard generation == selectionGeneration, id == selectedSessionID else { return }
            if let previous = selectedSession {
                guard snapshot.updatedAt >= previous.updatedAt else { return }
                if snapshot.totalRunCount - previous.totalRunCount > snapshot.runs.count {
                    // A disconnected client may have missed more than one page.
                    // Keep a contiguous latest window so older paging has no gaps.
                    earlierCursor = snapshot.nextBeforeRunID
                } else {
                    snapshot.runs = mergedRuns(older: previous.runs, newer: snapshot.runs)
                }
            } else {
                earlierCursor = snapshot.nextBeforeRunID
            }
            selectedSession = snapshot
            try await refreshTools(for: snapshot.runs, using: client, generation: generation)
        } catch {
            guard generation == selectionGeneration else { return }
            throw error
        }
    }

    private func refreshTools(for runs: [RunSnapshot], using client: any AppEngineClient, generation: UInt64) async throws {
        for run in runs where run.configuration?.profile != nil {
            if run.state != .running, toolInvocations[run.id] != nil, !runs.suffix(4).contains(where: { $0.id == run.id }) { continue }
            let latest = try await client.invocations(runID: run.id)
            guard generation == selectionGeneration else { return }
            toolInvocations[run.id] = latest
        }
    }

    func saveProfile(_ profile: ProviderProfile, apiKey: String?, clearCredential: Bool) async -> Bool {
        guard acceptsUserActions, let client, isConnected, !isSavingProfile else { return false }
        isSavingProfile = true
        defer { isSavingProfile = false }
        do {
            try profile.validate()
            profiles = try await client.saveProviderProfile(profile, apiKey: apiKey, clearCredential: clearCredential)
            if canChangeRunConfiguration { selectedProfileID = profile.id }
            return true
        } catch {
            errorMessage = L10n.errorFormat("app.error.profileSaveFailed", table: "AppMessages", error.localizedDescription)
            return false
        }
    }

    func decideApproval(_ invocation: ToolInvocationSnapshot, approved: Bool) {
        guard acceptsUserActions, let client, isConnected, !decidingApprovals.contains(invocation.id),
              selectedSession?.activeRun?.id == invocation.runID,
              toolInvocations[invocation.runID]?.contains(where: {
                  $0.id == invocation.id && $0.state == .pendingApproval && $0.requestHash == invocation.requestHash
              }) == true else { return }
        let generation = selectionGeneration
        decidingApprovals.insert(invocation.id)
        Task {
            defer { decidingApprovals.remove(invocation.id) }
            do {
                let updated = try await client.decideApproval(invocationID: invocation.id, requestHash: invocation.requestHash, approved: approved)
                guard generation == selectionGeneration else { return }
                if let index = toolInvocations[invocation.runID]?.firstIndex(where: { $0.id == invocation.id }) {
                    toolInvocations[invocation.runID]?[index] = updated
                }
            } catch {
                guard generation == selectionGeneration else { return }
                errorMessage = L10n.errorFormat("app.error.approvalStatusUnavailable", table: "AppMessages", error.localizedDescription)
            }
        }
    }

    private func mergedRuns(older: [RunSnapshot], newer: [RunSnapshot]) -> [RunSnapshot] {
        var indexed = Dictionary(uniqueKeysWithValues: older.map { ($0.id, $0) })
        for run in newer { indexed[run.id] = run }
        return indexed.values.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func disconnectAfterFailure(_ messageKey: String, error: Error) {
        guard !isShuttingDown else { return }
        isConnected = false
        pollTask?.cancel()
        errorMessage = L10n.errorFormat(messageKey, table: "AppMessages", error.localizedDescription)
    }

    private func startPolling(using client: any AppEngineClient, generation: UInt64) {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.connectionGeneration == generation else { return }
                do {
                    let page = try await client.events(after: self.cursor, sessionID: nil, runID: nil, limit: 256)
                    guard !Task.isCancelled, self.connectionGeneration == generation else { return }
                    if !page.events.isEmpty {
                        try await self.refreshSessions(using: client)
                        try await self.refreshSelectedSession(using: client)
                    }
                    guard !Task.isCancelled, self.connectionGeneration == generation else { return }
                    self.cursor = page.nextCursor
                    try await Task.sleep(for: .milliseconds(200))
                } catch is CancellationError {
                    return
                } catch {
                    guard self.connectionGeneration == generation else { return }
                    self.isConnected = false
                    self.errorMessage = L10n.errorFormat("app.error.runtimeConnectionLost", table: "AppMessages", error.localizedDescription)
                    return
                }
            }
        }
    }

    func beginExitDecision() {
        guard !isShuttingDown else { return }
        isExitDecisionPending = true
    }

    func cancelExitDecision() {
        guard !isShuttingDown else { return }
        isExitDecisionPending = false
    }

    /// Include sessions submitted through the shared CLI since the last UI poll.
    func requiresTerminationConfirmation() async -> Bool {
        if hasUnfinishedWork { return true }
        guard !isShuttingDown, let client, hostStarted || isConnected else { return false }
        do {
            try await refreshSessions(using: client)
            return hasUnfinishedWork
        } catch {
            // An unavailable snapshot must not be interpreted as an idle runtime.
            return true
        }
    }

    /// UI admission closes synchronously before the first suspension. EngineHost
    /// then closes RPC admission and awaits worker/runner cleanup before returning.
    func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        isShuttingDown = true
        isExitDecisionPending = false
        isConnected = false
        isConnecting = false
        connectionGeneration &+= 1
        selectionGeneration &+= 1
        connectionTask?.cancel()
        pollTask?.cancel()
        let ownedHost = host
        let task = Task<Void, Never> { if let ownedHost { await ownedHost.stop() } }
        shutdownTask = task
        await task.value
        engineInfo = nil
    }
}
