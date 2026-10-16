import Foundation
import LatheDomain
import LatheLocalization
import LathePersistence
import LatheProviders

public actor EngineRuntime {
    let store: SQLiteStore
    private let chunkDelay: Duration
    var workers: [UUID: Task<Void, Never>] = [:]
    let blobs: BlobStore
    let credentials: any CredentialStore
    let modelClient: ModelClient
    let dataDirectory: URL
    let runnerURL: URL
    var writeOwners: [String: UUID] = [:]
    var shuttingDown = false

    public init(databaseURL: URL, chunkDelay: Duration = .milliseconds(120), runnerURL: URL? = nil,
                credentials: any CredentialStore = KeychainCredentialStore(), modelClient: ModelClient = ModelClient()) throws {
        guard chunkDelay >= .zero else { throw LatheError.invalidRequest(L10n.errorText("runtime.stream.invalidDelay", table: "RuntimeMessages")) }
        let store = try SQLiteStore(databaseURL: databaseURL)
        try store.recoverInterruptedRuns()
        self.store = store
        self.chunkDelay = chunkDelay
        self.dataDirectory = databaseURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        self.blobs = try BlobStore(root: databaseURL.deletingLastPathComponent().appendingPathComponent("blobs"))
        self.credentials = credentials; self.modelClient = modelClient
        self.runnerURL = runnerURL ?? (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .deletingLastPathComponent().appendingPathComponent("lathe-runner")
    }

    public func listSessions(before: UUID? = nil, limit: Int = 50) async throws -> SessionPage {
        try store.listSessions(before: before, limit: limit)
    }

    public func session(id: UUID, beforeRunID: UUID? = nil, limit: Int = 4) async throws -> SessionSnapshot {
        try store.session(id: id, beforeRunID: beforeRunID, limit: limit)
    }

    public func createSession(title: String, workspacePath: String) async throws -> SessionSnapshot {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120, title.utf8.count <= 512 else {
            throw LatheError.invalidRequest(L10n.errorText("runtime.session.invalidTitle", table: "RuntimeMessages"))
        }
        guard workspacePath.hasPrefix("/"), !workspacePath.contains("\0") else {
            throw LatheError.invalidRequest(L10n.errorText("runtime.workspace.absolutePathRequired", table: "RuntimeMessages"))
        }
        let url = URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LatheError.invalidRequest(L10n.errorText("runtime.workspace.directoryMissing", table: "RuntimeMessages"))
        }
        return try store.createSession(title: title, workspacePath: url.path)
    }

    public func submit(sessionID: UUID, prompt: String, requestID: UUID, configuration: RunConfiguration? = nil) async throws -> RunSnapshot {
        guard !shuttingDown else { throw LatheError.conflict(L10n.errorText("runtime.engine.shuttingDown", table: "RuntimeMessages")) }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf8.count <= 32 * 1_024 else {
            throw LatheError.invalidRequest(L10n.errorText("runtime.prompt.invalidSize", table: "RuntimeMessages"))
        }
        try configuration?.validate()
        let result = try store.submit(sessionID: sessionID, prompt: prompt, requestID: requestID, configuration: configuration)
        if result.created {
            let runID = result.run.id
            if let configuration, let profile = configuration.profile {
                workers[runID] = Task { [weak self] in await self?.agentLoop(run: result.run, profile: profile, configuration: configuration) }
            } else {
                let chunks = Self.mockChunks(for: prompt)
                workers[runID] = Task { [weak self] in await self?.stream(runID: runID, chunks: chunks) }
            }
        }
        return result.run
    }

    public func cancel(runID: UUID) async throws -> RunSnapshot {
        let worker = workers[runID]
        // Stopping effects must not depend on being able to write a receipt.
        // The actor does not yield until the state update has been attempted.
        worker?.cancel()
        do {
            let run = try store.finish(runID: runID, state: .cancelled)
            try store.invalidatePendingInvocations(runID: runID)
            await worker?.value
            return run
        } catch {
            await worker?.value
            throw error
        }
    }

    public func shutdown() async {
        shuttingDown = true
        let pending = workers
        for (id, task) in pending {
            _ = try? store.finish(runID: id, state: .interrupted, reason: L10n.errorText("runtime.engine.stopped", table: "RuntimeMessages"))
            try? store.invalidatePendingInvocations(runID: id)
            task.cancel()
        }
        for task in pending.values { await task.value }
    }

    public func events(after cursor: Int64, sessionID: UUID?, runID: UUID? = nil, limit: Int = 256) async throws -> EventPage {
        try store.events(after: cursor, sessionID: sessionID, runID: runID, limit: limit)
    }

    private func stream(runID: UUID, chunks: [String]) async {
        defer { workers.removeValue(forKey: runID) }
        do {
            for chunk in chunks {
                try await Task.sleep(for: chunkDelay)
                try Task.checkCancellation()
                guard try store.append(runID: runID, text: chunk) else { return }
            }
            try Task.checkCancellation()
            try store.finish(runID: runID, state: .completed)
        } catch is CancellationError {
            // cancel() attempts the terminal receipt before awaiting this worker;
            // cleanup still runs when persistence fails and the caller gets that error.
        } catch {
            // If storage remains unavailable, startup recovery marks this run
            // interrupted. A failed write can never produce a completion event.
            _ = try? store.finish(runID: runID, state: .interrupted, reason: L10n.errorText("runtime.mock.storageFailed", table: "RuntimeMessages"))
        }
    }

    private static func mockChunks(for prompt: String) -> [String] {
        // A single grapheme can contain thousands of combining scalars. Bound
        // bytes as well as characters so neither output nor an event grows with it.
        var excerpt = ""
        for character in prompt.prefix(160) {
            let piece = String(character)
            guard excerpt.utf8.count + piece.utf8.count <= 512 else { break }
            excerpt.append(character)
        }
        let suffix = excerpt.utf8.count < prompt.utf8.count ? "…" : ""
        let response = L10n.format("runtime.mock.response", table: "RuntimeMessages", excerpt + suffix)
        let characters = Array(response)
        return stride(from: 0, to: characters.count, by: 24).map {
            String(characters[$0..<min($0 + 24, characters.count)])
        }
    }
}
