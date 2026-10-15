import CSQLite
import Darwin
import Foundation
import LatheDomain
import LathePersistence
import Testing

private struct AgentStorageFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lathe-agent-storage-\(UUID().uuidString)")
    var database: URL { root.appendingPathComponent("lathe.sqlite") }
    var blobs: URL { root.appendingPathComponent("blobs") }
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func cleanUp() { try? FileManager.default.removeItem(at: root) }
    func raw(_ body: (OpaquePointer) throws -> Void) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open(database.path, &pointer) == SQLITE_OK, let pointer else {
            throw LatheError.storage("fixture database open failed")
        }
        defer { sqlite3_close(pointer) }
        try body(pointer)
    }
}

private func fixtureSQL(_ database: OpaquePointer, _ sql: String) throws {
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw LatheError.storage(String(cString: sqlite3_errmsg(database)))
    }
}

private func toolSnapshot(runID: UUID, callID: String = UUID().uuidString, state: ToolInvocationState = .pendingApproval) -> ToolInvocationSnapshot {
    ToolInvocationSnapshot(runID: runID, callID: callID, name: "read_file", arguments: "{\"path\":\"test.txt\"}",
                           requestHash: String(repeating: "a", count: 64), summary: "Read test.txt", effect: .read, state: state)
}

struct AgentStorageTests {
    @Test func migrationKeepsLegacyRunsEventsAndRequestKeys() throws {
        let fixture = try AgentStorageFixture()
        defer { fixture.cleanUp() }
        let sessionID = UUID(), runID = UUID(), requestID = UUID()
        try fixture.raw { database in
            try fixtureSQL(database, """
                PRAGMA foreign_keys = ON;
                CREATE TABLE sessions (id TEXT PRIMARY KEY, title TEXT NOT NULL, workspace_path TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL);
                CREATE TABLE runs (id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id), prompt TEXT NOT NULL, response TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('running','completed','cancelled','interrupted')), started_at REAL NOT NULL, finished_at REAL);
                CREATE UNIQUE INDEX one_running_run_per_session ON runs(session_id) WHERE state = 'running';
                CREATE TABLE requests (request_id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id), prompt TEXT NOT NULL, run_id TEXT NOT NULL UNIQUE REFERENCES runs(id));
                CREATE TABLE events (sequence INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL REFERENCES sessions(id), run_id TEXT REFERENCES runs(id), kind TEXT NOT NULL, text TEXT, timestamp REAL NOT NULL);
                CREATE INDEX session_events ON events(session_id, sequence);
                INSERT INTO sessions VALUES ('\(sessionID)', 'legacy', '/tmp', 100, 101);
                INSERT INTO runs VALUES ('\(runID)', '\(sessionID)', 'old prompt', 'saved output', 'running', 101, NULL);
                INSERT INTO requests VALUES ('\(requestID)', '\(sessionID)', 'old prompt', '\(runID)');
                INSERT INTO events VALUES (42, '\(sessionID)', '\(runID)', 'runStarted', NULL, 101);
                PRAGMA user_version = 1;
                """)
        }
        let store = try SQLiteStore(databaseURL: fixture.database)
        let previous = try store.run(id: runID)
        #expect(previous.configuration == nil)
        #expect(previous.response == "saved output")
        let replay = try store.submit(sessionID: sessionID, prompt: "old prompt", requestID: requestID)
        #expect(!replay.created && replay.run == previous)
        #expect(try store.events(after: 0, sessionID: sessionID, limit: 10).events.map(\.sequence) == [42])
        #expect(try store.finish(runID: runID, state: .failed).state == .failed)
        #expect(try store.events(after: 42, sessionID: sessionID, limit: 10).events.map(\.kind) == [.runFailed])
        try fixture.raw { database in
            var statement: OpaquePointer?
            #expect(sqlite3_prepare_v2(database, "PRAGMA foreign_key_check", -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            #expect(sqlite3_step(statement) == SQLITE_DONE)
            try fixtureSQL(database, "PRAGMA foreign_keys = ON")
            #expect(sqlite3_exec(database, "DELETE FROM runs", nil, nil, nil) == SQLITE_CONSTRAINT)
        }
        let reopened = try SQLiteStore(databaseURL: fixture.database)
        #expect(try reopened.run(id: runID).state == .failed)
    }

    @Test func frozenConfigurationParticipatesInIdempotencyAndProfilesStayMetadata() throws {
        let fixture = try AgentStorageFixture()
        defer { fixture.cleanUp() }
        let store = try SQLiteStore(databaseURL: fixture.database)
        var profile = ProviderProfile(name: "fixture", api: .openAIChat, baseURL: "https://models.example.test/v1", model: "fixture-model")
        try store.saveProviderProfile(profile)
        #expect(try store.listProviderProfiles() == [profile])
        let configuration = RunConfiguration(profile: profile)
        let session = try store.createSession(title: "config", workspacePath: fixture.root.path)
        let requestID = UUID()
        let original = try store.submit(sessionID: session.id, prompt: "test", requestID: requestID, configuration: configuration).run
        profile.model = "different-model"
        try store.saveProviderProfile(profile)
        #expect(try store.run(id: original.id).configuration == configuration)
        #expect(try store.submit(sessionID: session.id, prompt: "test", requestID: requestID, configuration: configuration).created == false)
        #expect(throws: LatheError.self) {
            try store.submit(sessionID: session.id, prompt: "test", requestID: requestID, configuration: RunConfiguration(profile: profile))
        }
        #expect(throws: LatheError.self) { try store.submit(sessionID: session.id, prompt: "test", requestID: requestID) }
        profile.baseURL = "https://models.example.test/v1?key=forbidden-fixture"
        #expect(throws: LatheError.self) { try store.saveProviderProfile(profile) }
        #expect(try store.listProviderProfiles().count == 1)
    }

    @Test func toolProjectionAndEventsAreAtomicAndReceiptsCannotReplay() throws {
        let fixture = try AgentStorageFixture()
        defer { fixture.cleanUp() }
        let store = try SQLiteStore(databaseURL: fixture.database)
        let session = try store.createSession(title: "tools", workspacePath: fixture.root.path)
        let run = try store.submit(sessionID: session.id, prompt: "test", requestID: UUID()).run
        var snapshot = toolSnapshot(runID: run.id)
        snapshot.beforeBlobID = String(repeating: "b", count: 64)
        try store.saveInvocation(snapshot)
        let before = try store.events(after: 0, sessionID: session.id, limit: 256).nextCursor
        try fixture.raw { database in
            try fixtureSQL(database, "CREATE TRIGGER reject_tool BEFORE INSERT ON events WHEN NEW.kind = 'toolUpdated' BEGIN SELECT RAISE(ABORT, 'fixture tool event failure'); END")
        }
        snapshot.state = .approved
        #expect(throws: LatheError.self) { try store.saveInvocation(snapshot) }
        #expect(try store.invocation(id: snapshot.id).state == .pendingApproval)
        #expect(try store.events(after: before, sessionID: session.id, limit: 256).events.isEmpty)
        try fixture.raw { try fixtureSQL($0, "DROP TRIGGER reject_tool") }
        try store.saveInvocation(snapshot)
        var changed = snapshot
        changed.arguments = "{}"
        #expect(throws: LatheError.self) { try store.saveInvocation(changed) }
        changed = snapshot
        changed.beforeBlobID = String(repeating: "c", count: 64)
        #expect(throws: LatheError.self) { try store.saveInvocation(changed) }
        snapshot.state = .executing
        try store.saveInvocation(snapshot)
        try store.finish(runID: run.id, state: .cancelled)
        snapshot.state = .completed
        snapshot.output = "Result arrived during cancellation"
        try store.saveInvocation(snapshot)
        let cursor = try store.events(after: 0, sessionID: session.id, limit: 256).nextCursor
        try store.saveInvocation(snapshot)
        #expect(try store.events(after: cursor, sessionID: session.id, limit: 256).events.isEmpty)
        snapshot.state = .executing
        #expect(throws: LatheError.self) { try store.saveInvocation(snapshot) }
        #expect(throws: LatheError.self) { try store.saveInvocation(toolSnapshot(runID: run.id, state: .approved)) }
        #expect(try store.invocations(runID: run.id).count == 1)
    }

    @Test func recoveryInvalidatesConsentAndPreservesUnknownExecutionWithoutReplay() throws {
        let fixture = try AgentStorageFixture()
        defer { fixture.cleanUp() }
        let store = try SQLiteStore(databaseURL: fixture.database)
        let session = try store.createSession(title: "recovery", workspacePath: fixture.root.path)
        let run = try store.submit(sessionID: session.id, prompt: "test", requestID: UUID()).run
        let pending = toolSnapshot(runID: run.id)
        let approved = toolSnapshot(runID: run.id, state: .approved)
        var executing = toolSnapshot(runID: run.id, state: .approved)
        try store.saveInvocation(pending)
        try store.saveInvocation(approved)
        try store.saveInvocation(executing)
        executing.state = .executing
        try store.saveInvocation(executing)
        try store.invalidatePendingInvocations(runID: run.id)
        #expect(try store.invocation(id: pending.id).state == .cancelled)
        #expect(try store.invocation(id: approved.id).state == .cancelled)
        #expect(try store.invocation(id: executing.id).state == .executing)
        // Crash after cancellation commits, before a runner receipt arrives.
        try store.finish(runID: run.id, state: .cancelled)
        let liveSession = try store.createSession(title: "still running", workspacePath: fixture.root.path)
        let live = try store.submit(sessionID: liveSession.id, prompt: "test", requestID: UUID()).run
        let liveApproval = toolSnapshot(runID: live.id, state: .approved)
        try store.saveInvocation(liveApproval)
        try store.recoverInterruptedRuns()
        #expect(try store.run(id: run.id).state == .cancelled)
        #expect(try store.invocation(id: executing.id).state == .unknown)
        #expect(try store.run(id: live.id).state == .interrupted)
        #expect(try store.invocation(id: liveApproval.id).state == .cancelled)
        let cursor = try store.events(after: 0, sessionID: nil, limit: 256).nextCursor
        try store.recoverInterruptedRuns()
        #expect(try store.events(after: cursor, sessionID: nil, limit: 256).events.isEmpty)
        #expect(throws: LatheError.self) { try store.saveInvocation(executing) }
    }

    @Test func toolJournalAndHistoryMappingsAreBounded() throws {
        let fixture = try AgentStorageFixture()
        defer { fixture.cleanUp() }
        let store = try SQLiteStore(databaseURL: fixture.database)
        let session = try store.createSession(title: "bounds", workspacePath: fixture.root.path)
        let run = try store.submit(sessionID: session.id, prompt: "test", requestID: UUID()).run
        var large = toolSnapshot(runID: run.id)
        large.output = String(repeating: "x", count: 8193)
        #expect(throws: LatheError.self) { try store.saveInvocation(large) }
        for _ in 0..<64 { try store.saveInvocation(toolSnapshot(runID: run.id)) }
        #expect(try store.invocations(runID: run.id).count == 64)
        #expect(throws: LatheError.self) { try store.saveInvocation(toolSnapshot(runID: run.id)) }
        #expect(try store.modelHistory(runID: run.id) == nil)
        let digest = String(repeating: "b", count: 64)
        try store.saveModelHistory(runID: run.id, blobID: digest)
        #expect(try store.modelHistory(runID: run.id) == digest)
        #expect(throws: LatheError.self) { try store.saveModelHistory(runID: run.id, blobID: "../../escape") }
    }

    @Test func blobPublicationIsPrivateVerifiedAndNeverOverwritesTampering() throws {
        let fixture = try AgentStorageFixture()
        defer { fixture.cleanUp() }
        let store = try BlobStore(root: fixture.blobs, maxBytes: 1024)
        let bytes = Data([0, 255, 195, 40, 13, 10])
        let id = try store.put(bytes)
        #expect(id.count == 64)
        #expect(try store.read(id) == bytes)
        #expect(try store.put(bytes) == id)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.blobs.path) == [id])
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.blobs.appendingPathComponent(id).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(throws: LatheError.self) { try store.put(Data(count: 1025)) }
        for invalid in ["../escape", String(repeating: "F", count: 64), ""] {
            #expect(throws: LatheError.self) { try store.read(invalid) }
        }
        let path = fixture.blobs.appendingPathComponent(id)
        try Data("tampered".utf8).write(to: path)
        #expect(throws: LatheError.self) { try store.read(id) }
        #expect(throws: LatheError.self) { try store.put(bytes) }
        #expect(try Data(contentsOf: path) == Data("tampered".utf8))
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: fixture.database)
        #expect(throws: LatheError.self) { try store.read(id) }
        #expect(throws: LatheError.self) { try store.put(bytes) }
        let link = fixture.root.appendingPathComponent("blob-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.blobs)
        #expect(throws: LatheError.self) { try BlobStore(root: link) }
    }

    @Test func concurrentBlobPublicationDeduplicatesWithoutPartialReads() async throws {
        let fixture = try AgentStorageFixture()
        defer { fixture.cleanUp() }
        let store = try BlobStore(root: fixture.blobs)
        let bytes = Data(repeating: 42, count: 128 * 1024)
        let ids = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<12 { group.addTask { try store.put(bytes) } }
            var ids: [String] = []
            for try await id in group { ids.append(id) }
            return ids
        }
        #expect(Set(ids).count == 1)
        #expect(try store.read(ids[0]) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.blobs.path) == [ids[0]])
    }
}
