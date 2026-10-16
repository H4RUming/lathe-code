import CSQLite
import Foundation
import LatheDomain
@testable import LatheLocalization
import LathePersistence
import LatheRuntime
import Testing

private struct RuntimeFixture {
    let root: URL
    var database: URL { root.appendingPathComponent("state/lathe.sqlite") }
    var workspace: URL { root.appendingPathComponent("workspace") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lathe-runtime-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

private func finishedRun(_ runtime: EngineRuntime, sessionID: UUID, runID: UUID) async throws -> RunSnapshot {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        let session = try await runtime.session(id: sessionID)
        if let run = session.runs.first(where: { $0.id == runID }), run.state != .running { return run }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw LatheError.transport("테스트 실행이 완료되지 않았습니다.")
}

struct RuntimeTests {
@Test func runReplaySkipsOldHistoryWithoutLosingEarlierDeltas() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.cleanUp() }
    let store = try SQLiteStore(databaseURL: fixture.database)
    let session = try store.createSession(title: "large history", workspacePath: fixture.workspace.path)
    for _ in 0..<140 {
        let run = try store.submit(sessionID: session.id, prompt: "old", requestID: UUID()).run
        try store.finish(runID: run.id, state: .cancelled)
    }
    let current = try store.submit(sessionID: session.id, prompt: "current", requestID: UUID()).run
    try store.append(runID: current.id, text: "already streamed")
    let replay = try store.events(after: 0, sessionID: session.id, runID: current.id, limit: 256)
    #expect(replay.events.map(\.kind) == [.runStarted, .textDelta])
    #expect(replay.events.last?.text == "already streamed")
    try store.finish(runID: current.id, state: .completed)
    let terminal = try store.events(after: replay.nextCursor, sessionID: session.id, runID: current.id, limit: 256)
    #expect(terminal.events.map(\.kind) == [.runCompleted])
    let other = try store.createSession(title: "other", workspacePath: fixture.workspace.path)
    #expect(throws: LatheError.self) {
        try store.events(after: 0, sessionID: other.id, runID: current.id, limit: 256)
    }
}

@Test(arguments: ["ko", "en"])
func mockStreamPersistsAndReplaysExactly(language: String) async throws {
    try await L10n.$localeOverride.withValue(Locale(identifier: language)) {
        let fixture = try RuntimeFixture()
        defer { fixture.cleanUp() }
        let runtime = try EngineRuntime(databaseURL: fixture.database, chunkDelay: .milliseconds(1))
        let session = try await runtime.createSession(title: "스트림", workspacePath: fixture.workspace.path)
        let prompt = "이 코드를 설명해 줘 — 100% %@ %lld"
        let started = try await runtime.submit(sessionID: session.id, prompt: prompt, requestID: UUID())
        let completed = try await finishedRun(runtime, sessionID: session.id, runID: started.id)
        #expect(completed.state == .completed)
        #expect(completed.finishedAt != nil)
        #expect(completed.response == L10n.format("runtime.mock.response", table: "RuntimeMessages", prompt))
        #expect(completed.response.contains(prompt))

        var cursor: Int64 = 0
        var replay: [EngineEvent] = []
        while true {
            let page = try await runtime.events(after: cursor, sessionID: nil, limit: 3)
            #expect(page.nextCursor >= cursor)
            replay += page.events
            cursor = page.nextCursor
            if page.events.isEmpty { break }
        }
        #expect(replay.map(\.sequence) == Array(1...Int64(replay.count)))
        #expect(replay.first?.kind == .sessionCreated)
        #expect(replay.last?.kind == .runCompleted)
        #expect(replay.filter { $0.kind == .runStarted }.count == 1)
        #expect(replay.filter { $0.kind == .textDelta }.compactMap(\.text).joined() == completed.response)

        let reopened = try EngineRuntime(databaseURL: fixture.database)
        let restored = try await reopened.session(id: session.id)
        #expect(restored.runs == [completed])
        #expect(try await reopened.events(after: cursor, sessionID: nil).events.isEmpty)
    }
}

@Test func idempotencySurvivesCompletionAndRestartAndRejectsChangedPayload() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.cleanUp() }
    let runtime = try EngineRuntime(databaseURL: fixture.database, chunkDelay: .milliseconds(1))
    let session = try await runtime.createSession(title: "중복 요청", workspacePath: fixture.workspace.path)
    let requestID = UUID()
    let first = try await runtime.submit(sessionID: session.id, prompt: "original", requestID: requestID)
    let duplicate = try await runtime.submit(sessionID: session.id, prompt: "original", requestID: requestID)
    #expect(duplicate.id == first.id)
    do {
        _ = try await runtime.submit(sessionID: session.id, prompt: "changed", requestID: requestID)
        Issue.record("다른 payload가 같은 request ID로 수락되었습니다.")
    } catch LatheError.conflict { }
    let completed = try await finishedRun(runtime, sessionID: session.id, runID: first.id)

    let reopened = try EngineRuntime(databaseURL: fixture.database)
    let replayed = try await reopened.submit(sessionID: session.id, prompt: "original", requestID: requestID)
    #expect(replayed == completed)
    let other = try await reopened.createSession(title: "다른 세션", workspacePath: fixture.workspace.path)
    do {
        _ = try await reopened.submit(sessionID: other.id, prompt: "original", requestID: requestID)
        Issue.record("다른 세션이 기존 request ID를 사용했습니다.")
    } catch LatheError.conflict { }
    #expect(try await reopened.session(id: session.id).runs.count == 1)
    #expect(try await reopened.events(after: 0, sessionID: session.id).events.filter { $0.kind == .runStarted }.count == 1)
}

@Test func concurrentSubmissionsHaveOnlyOneActiveRun() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.cleanUp() }
    let runtime = try EngineRuntime(databaseURL: fixture.database, chunkDelay: .seconds(1))
    let session = try await runtime.createSession(title: "동시 요청", workspacePath: fixture.workspace.path)
    let accepted = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
        for index in 0..<12 {
            group.addTask {
                do {
                    _ = try await runtime.submit(sessionID: session.id, prompt: "request \(index)", requestID: UUID())
                    return true
                } catch LatheError.conflict {
                    return false
                } catch {
                    Issue.record("예상하지 못한 오류: \(error)")
                    return false
                }
            }
        }
        var count = 0
        for await success in group { if success { count += 1 } }
        return count
    }
    #expect(accepted == 1)
    let current = try await runtime.session(id: session.id)
    #expect(current.runs.count == 1)
    let active = try #require(current.activeRun)
    _ = try await runtime.cancel(runID: active.id)
    let next = try await runtime.submit(sessionID: session.id, prompt: "다음 실행", requestID: UUID())
    _ = try await runtime.cancel(runID: next.id)
}

@Test func cancellationIsTerminalAndHasNoLateDeltas() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.cleanUp() }
    let runtime = try EngineRuntime(databaseURL: fixture.database, chunkDelay: .milliseconds(20))
    let session = try await runtime.createSession(title: "취소", workspacePath: fixture.workspace.path)
    let started = try await runtime.submit(sessionID: session.id, prompt: "취소할 실행", requestID: UUID())
    let deadline = ContinuousClock.now + .seconds(3)
    while try await runtime.session(id: session.id).runs[0].response.isEmpty {
        guard ContinuousClock.now < deadline else { throw LatheError.transport("첫 delta 대기 실패") }
        try await Task.sleep(for: .milliseconds(5))
    }
    let cancelled = try await runtime.cancel(runID: started.id)
    #expect(cancelled.state == .cancelled)
    #expect(!cancelled.response.isEmpty)
    let page = try await runtime.events(after: 0, sessionID: session.id)
    #expect(page.events.last?.kind == .runCancelled)
    try await Task.sleep(for: .milliseconds(120))
    #expect(try await runtime.session(id: session.id).runs[0] == cancelled)
    #expect(try await runtime.events(after: page.nextCursor, sessionID: nil).events.isEmpty)
    #expect(try await runtime.cancel(runID: started.id) == cancelled)
}

@Test func recoveryInterruptsOnlyUnfinishedRunsOnceAndKeepsRequestKeys() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.cleanUp() }
    let requestID = UUID()
    let seeded: (UUID, UUID) = try {
        let store = try SQLiteStore(databaseURL: fixture.database)
        let session = try store.createSession(title: "crash fixture", workspacePath: fixture.workspace.path)
        let result = try store.submit(sessionID: session.id, prompt: "pending", requestID: requestID)
        try store.append(runID: result.run.id, text: "저장된 부분 응답")
        return (session.id, result.run.id)
    }()
    let runtime = try EngineRuntime(databaseURL: fixture.database)
    let recovered = try await runtime.session(id: seeded.0).runs[0]
    #expect(recovered.id == seeded.1)
    #expect(recovered.state == .interrupted)
    #expect(recovered.response == "저장된 부분 응답")
    let retry = try await runtime.submit(sessionID: seeded.0, prompt: "pending", requestID: requestID)
    #expect(retry == recovered)
    let page = try await runtime.events(after: 0, sessionID: seeded.0)
    #expect(page.events.filter { $0.kind == .runInterrupted }.count == 1)
    #expect(page.events.last?.kind == .runInterrupted)
    let reopened = try EngineRuntime(databaseURL: fixture.database)
    #expect(try await reopened.events(after: page.nextCursor, sessionID: nil).events.isEmpty)
}

@Test func filteredReplayDoesNotSkipMatchingEventsAndAdvancesPastOtherSessions() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.cleanUp() }
    let runtime = try EngineRuntime(databaseURL: fixture.database, chunkDelay: .seconds(1))
    let first = try await runtime.createSession(title: "하나", workspacePath: fixture.workspace.path)
    let second = try await runtime.createSession(title: "둘", workspacePath: fixture.workspace.path)
    let run = try await runtime.submit(sessionID: first.id, prompt: "test", requestID: UUID())
    _ = try await runtime.cancel(runID: run.id)
    let a = try await runtime.events(after: 0, sessionID: first.id, limit: 1)
    let b = try await runtime.events(after: a.nextCursor, sessionID: first.id, limit: 1)
    let c = try await runtime.events(after: b.nextCursor, sessionID: first.id, limit: 1)
    #expect(a.events.map(\.kind) == [.sessionCreated])
    #expect(b.events.map(\.kind) == [.runStarted])
    #expect(c.events.map(\.kind) == [.runCancelled])
    let other = try await runtime.events(after: 0, sessionID: second.id, limit: 20)
    #expect(other.events.count == 1)
    #expect(other.nextCursor == c.nextCursor)
    #expect(try await runtime.events(after: other.nextCursor, sessionID: second.id).events.isEmpty)
}

@Test func validationRejectsInvalidInputsWithoutPersistingEvents() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.cleanUp() }
    let runtime = try EngineRuntime(databaseURL: fixture.database)
    for title in ["   ", String(repeating: "a", count: 121)] {
        do {
            _ = try await runtime.createSession(title: title, workspacePath: fixture.workspace.path)
            Issue.record("잘못된 title이 수락되었습니다.")
        } catch LatheError.invalidRequest { }
    }
    for path in ["relative/path", fixture.root.appendingPathComponent("missing").path] {
        do {
            _ = try await runtime.createSession(title: "test", workspacePath: path)
            Issue.record("잘못된 workspace가 수락되었습니다.")
        } catch LatheError.invalidRequest { }
    }
    #expect(try await runtime.events(after: 0, sessionID: nil).events.isEmpty)
    let link = fixture.root.appendingPathComponent("workspace-link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.workspace)
    let session = try await runtime.createSession(title: "  valid  ", workspacePath: link.path)
    #expect(session.title == "valid")
    #expect(session.workspacePath == fixture.workspace.resolvingSymlinksInPath().path)
    for prompt in ["\n\t ", String(repeating: "한", count: 11_000)] {
        do {
            _ = try await runtime.submit(sessionID: session.id, prompt: prompt, requestID: UUID())
            Issue.record("잘못된 prompt가 수락되었습니다.")
        } catch LatheError.invalidRequest { }
    }
    #expect(try await runtime.session(id: session.id).runs.isEmpty)
    #expect(try await runtime.events(after: 0, sessionID: nil).events.count == 1)
}

@Test func sessionAndRunPagesExposeAllHistoryWithStableCursors() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.cleanUp() }
    let runtime = try EngineRuntime(databaseURL: fixture.database, chunkDelay: .seconds(1))
    var sessions: [SessionSnapshot] = []
    for index in 0..<5 {
        sessions.append(try await runtime.createSession(title: "page \(index)", workspacePath: fixture.workspace.path))
    }
    let target = sessions[0]
    var runIDs: [UUID] = []
    for index in 0..<10 {
        let run = try await runtime.submit(sessionID: target.id, prompt: "run \(index)", requestID: UUID())
        runIDs.append(run.id)
        _ = try await runtime.cancel(runID: run.id)
    }
    let first = try await runtime.listSessions(limit: 2)
    #expect(first.sessions.map(\.id) == sessions.suffix(2).reversed().map(\.id))
    // Updating an older session must not move it across an immutable list cursor.
    let active = try await runtime.submit(sessionID: sessions[1].id, prompt: "active", requestID: UUID())
    let second = try await runtime.listSessions(before: first.nextBefore, limit: 2)
    let third = try await runtime.listSessions(before: second.nextBefore, limit: 2)
    let all = first.sessions + second.sessions + third.sessions
    #expect(all.map(\.id) == sessions.reversed().map(\.id))
    #expect(all.allSatisfy { $0.runs.isEmpty })
    #expect(all.first(where: { $0.id == target.id })?.totalRunCount == 10)
    #expect(all.first(where: { $0.id == sessions[1].id })?.activeRunID == active.id)
    #expect(third.nextBefore == nil)
    _ = try await runtime.cancel(runID: active.id)

    let newest = try await runtime.session(id: target.id)
    let middle = try await runtime.session(id: target.id, beforeRunID: newest.nextBeforeRunID)
    let oldest = try await runtime.session(id: target.id, beforeRunID: middle.nextBeforeRunID)
    #expect(newest.totalRunCount == 10)
    #expect(newest.runs.count == 4 && middle.runs.count == 4 && oldest.runs.count == 2)
    #expect((oldest.runs + middle.runs + newest.runs).map(\.id) == runIDs)
    #expect(oldest.nextBeforeRunID == nil)
    do {
        _ = try await runtime.session(id: target.id, beforeRunID: active.id)
        Issue.record("다른 세션의 실행 cursor가 수락되었습니다.")
    } catch LatheError.notFound { }
    for invalid in [0, 5] {
        do {
            _ = try await runtime.session(id: target.id, limit: invalid)
            Issue.record("잘못된 실행 페이지 크기가 수락되었습니다.")
        } catch LatheError.invalidRequest { }
    }
    for invalid in [0, 51] {
        do {
            _ = try await runtime.listSessions(limit: invalid)
            Issue.record("잘못된 세션 페이지 크기가 수락되었습니다.")
        } catch LatheError.invalidRequest { }
    }
}

@Test func maximumEscapedPromptsAndGraphemesKeepPagesBounded() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.cleanUp() }
    let runtime = try EngineRuntime(databaseURL: fixture.database, chunkDelay: .zero)
    let session = try await runtime.createSession(title: "bounded", workspacePath: fixture.workspace.path)
    let prompt = String(repeating: "\u{0001}", count: 32 * 1_024 - 1) + "a"
    for _ in 0..<4 {
        let run = try await runtime.submit(sessionID: session.id, prompt: prompt, requestID: UUID())
        let completed = try await finishedRun(runtime, sessionID: session.id, runID: run.id)
        #expect(completed.prompt == prompt)
    }
    let page = try await runtime.session(id: session.id)
    #expect(try JSONEncoder().encode(page).count < 900 * 1_024)
    #expect(try JSONEncoder().encode(await runtime.events(after: 0, sessionID: nil, limit: 1_024)).count < 900 * 1_024)
    let giantGrapheme = "a" + String(repeating: "\u{0301}", count: 16_000)
    #expect(giantGrapheme.count == 1)
    let run = try await runtime.submit(sessionID: session.id, prompt: giantGrapheme, requestID: UUID())
    let completed = try await finishedRun(runtime, sessionID: session.id, runID: run.id)
    #expect(completed.response.utf8.count < 2_048)
    #expect(completed.response.contains("…"))
}

@Test(arguments: ["ko", "en"])
func eventWriteFailureRollsBackProjectionAndCanRetry(language: String) throws {
    try L10n.$localeOverride.withValue(Locale(identifier: language)) {
        let fixture = try RuntimeFixture()
        defer { fixture.cleanUp() }
        let store = try SQLiteStore(databaseURL: fixture.database)
        let session = try store.createSession(title: "atomic", workspacePath: fixture.workspace.path)
        let run = try store.submit(sessionID: session.id, prompt: "atomic write", requestID: UUID()).run
        var connection: OpaquePointer?
        #expect(sqlite3_open(fixture.database.path, &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        let database = try #require(connection)
        let trigger = "CREATE TRIGGER reject_delta BEFORE INSERT ON events WHEN NEW.kind = 'textDelta' BEGIN SELECT RAISE(ABORT, 'injected event failure 100% %@'); END"
        #expect(sqlite3_exec(database, trigger, nil, nil, nil) == SQLITE_OK)
        do {
            try store.append(runID: run.id, text: "must roll back")
            Issue.record("주입한 이벤트 쓰기 오류가 발생하지 않았습니다.")
        } catch LatheError.storage(let message) {
            #expect(message == L10n.format("storage.database.operationFailed", table: "StorageErrors", "injected event failure 100% %@"))
        }
        #expect(try store.run(id: run.id).response.isEmpty)
        #expect(try store.events(after: 0, sessionID: session.id, limit: 256).events.map(\.kind) == [.sessionCreated, .runStarted])
        #expect(sqlite3_exec(database, "DROP TRIGGER reject_delta", nil, nil, nil) == SQLITE_OK)
        #expect(try store.append(runID: run.id, text: "committed"))
        #expect(try store.run(id: run.id).response == "committed")
        #expect(try store.events(after: 0, sessionID: session.id, limit: 256).events.last?.text == "committed")
    }
}
}
