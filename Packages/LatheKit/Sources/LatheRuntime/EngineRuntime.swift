import Foundation
import LatheDomain
import LathePersistence

public actor EngineRuntime {
    private let store: SQLiteStore
    private let chunkDelay: Duration
    private var workers: [UUID: Task<Void, Never>] = [:]

    public init(databaseURL: URL, chunkDelay: Duration = .milliseconds(120)) throws {
        guard chunkDelay >= .zero else { throw LatheError.invalidRequest("스트림 지연은 0 이상이어야 합니다.") }
        let store = try SQLiteStore(databaseURL: databaseURL)
        try store.recoverInterruptedRuns()
        self.store = store
        self.chunkDelay = chunkDelay
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
            throw LatheError.invalidRequest("세션 이름은 1~120자, UTF-8 512바이트 이하여야 합니다.")
        }
        guard workspacePath.hasPrefix("/"), !workspacePath.contains("\0") else {
            throw LatheError.invalidRequest("프로젝트의 절대 경로가 필요합니다.")
        }
        let url = URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LatheError.invalidRequest("프로젝트 경로에 디렉터리가 없습니다.")
        }
        return try store.createSession(title: title, workspacePath: url.path)
    }

    public func submit(sessionID: UUID, prompt: String, requestID: UUID) async throws -> RunSnapshot {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf8.count <= 32 * 1_024 else {
            throw LatheError.invalidRequest("요청은 비어 있지 않아야 하며 UTF-8 32KiB 이하여야 합니다.")
        }
        let result = try store.submit(sessionID: sessionID, prompt: prompt, requestID: requestID)
        if result.created {
            let runID = result.run.id
            let chunks = Self.mockChunks(for: prompt)
            workers[runID] = Task { [weak self] in await self?.stream(runID: runID, chunks: chunks) }
        }
        return result.run
    }

    public func cancel(runID: UUID) async throws -> RunSnapshot {
        let run = try store.finish(runID: runID, state: .cancelled)
        workers.removeValue(forKey: runID)?.cancel()
        return run
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
            // cancel() commits the terminal state before cancelling this worker.
        } catch {
            // If storage remains unavailable, startup recovery marks this run
            // interrupted. A failed write can never produce a completion event.
            _ = try? store.finish(runID: runID, state: .interrupted, reason: "mock 스트림 저장에 실패했습니다.")
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
        let response = """
        M0 mock 실행입니다. 실제 모델, 파일 도구, shell을 호출하지 않았습니다.

        받은 요청: \(excerpt)\(suffix)

        현재 단계에서는 세션 저장, 스트리밍, 취소, 이벤트 재연결을 확인할 수 있습니다. 코드나 프로젝트 파일은 변경하지 않았습니다.
        """
        let characters = Array(response)
        return stride(from: 0, to: characters.count, by: 24).map {
            String(characters[$0..<min($0 + 24, characters.count)])
        }
    }
}
