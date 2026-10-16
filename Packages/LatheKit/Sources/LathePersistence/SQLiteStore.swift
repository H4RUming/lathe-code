import CSQLite
import Foundation
import LatheDomain
import LatheLocalization

/// Synchronous by design. The owning EngineRuntime actor serializes access;
/// the engine's process lock prevents another engine from recovering live runs.
public final class SQLiteStore {
    private var database: OpaquePointer?

    public init(databaseURL: URL) throws {
        guard databaseURL.isFileURL else {
            throw LatheError.invalidRequest(L10n.text("storage.database.localFileRequired", table: "StorageErrors"))
        }
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let result = sqlite3_open_v2(
            databaseURL.path, &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
        )
        guard result == SQLITE_OK else {
            let error = LatheError.storage(L10n.format("storage.database.openFailed", table: "StorageErrors", databaseDetail()))
            sqlite3_close(database)
            database = nil
            throw error
        }
        do {
            sqlite3_busy_timeout(database, 5_000)
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            try migrate()
            try execute("CREATE INDEX IF NOT EXISTS run_events ON events(run_id, sequence)")
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    public func listSessions(before: UUID? = nil, limit: Int = 50) throws -> SessionPage {
        guard (1...50).contains(limit) else {
            throw LatheError.invalidRequest(L10n.text("storage.session.invalidPageLimit", table: "StorageErrors"))
        }
        var sql = "SELECT id FROM sessions"
        var values: [Value] = []
        if let before {
            guard let row = try query("SELECT rowid FROM sessions WHERE id = ?", [.text(before.uuidString)]).first else {
                throw LatheError.notFound(L10n.text("storage.session.cursorNotFound", table: "StorageErrors"))
            }
            sql += " WHERE rowid < ?"
            values.append(row[0])
        }
        sql += " ORDER BY rowid DESC LIMIT ?"
        values.append(.integer(Int64(limit + 1)))
        let rows = try query(sql, values)
        let sessions = try rows.prefix(limit).map { try sessionMetadata(id: uuid($0[0])) }
        return SessionPage(sessions: sessions, nextBefore: rows.count > limit ? sessions.last?.id : nil)
    }

    public func session(id: UUID, beforeRunID: UUID? = nil, limit: Int = 4) throws -> SessionSnapshot {
        guard (1...4).contains(limit) else {
            throw LatheError.invalidRequest(L10n.text("storage.run.invalidPageLimit", table: "StorageErrors"))
        }
        let metadata = try sessionMetadata(id: id)
        var sql = "SELECT id, session_id, prompt, response, state, started_at, finished_at, configuration FROM runs WHERE session_id = ?"
        var values: [Value] = [.text(id.uuidString)]
        if let beforeRunID {
            guard let row = try query(
                "SELECT rowid FROM runs WHERE id = ? AND session_id = ?",
                [.text(beforeRunID.uuidString), .text(id.uuidString)]
            ).first else { throw LatheError.notFound(L10n.text("storage.run.cursorNotFound", table: "StorageErrors")) }
            sql += " AND rowid < ?"
            values.append(row[0])
        }
        sql += " ORDER BY rowid DESC LIMIT ?"
        values.append(.integer(Int64(limit + 1)))
        let rows = try query(sql, values)
        let runs = try rows.prefix(limit).reversed().map(decodeRun)
        return SessionSnapshot(
            id: metadata.id, title: metadata.title, workspacePath: metadata.workspacePath,
            createdAt: metadata.createdAt, updatedAt: metadata.updatedAt, runs: runs,
            totalRunCount: metadata.totalRunCount,
            nextBeforeRunID: rows.count > limit ? runs.first?.id : nil, activeRunID: metadata.activeRunID
        )
    }

    private func sessionMetadata(id: UUID) throws -> SessionSnapshot {
        guard let row = try query(
            """
            SELECT id, title, workspace_path, created_at, updated_at,
              (SELECT COUNT(*) FROM runs WHERE session_id = sessions.id),
              (SELECT id FROM runs WHERE session_id = sessions.id AND state = 'running')
            FROM sessions WHERE id = ?
            """,
            [.text(id.uuidString)]
        ).first else { throw LatheError.notFound(L10n.text("storage.session.notFound", table: "StorageErrors")) }
        return SessionSnapshot(
            id: try uuid(row[0]), title: try string(row[1]), workspacePath: try string(row[2]),
            createdAt: try date(row[3]), updatedAt: try date(row[4]),
            totalRunCount: try Int(integer(row[5])), activeRunID: try optionalString(row[6]).map { try uuid(.text($0)) }
        )
    }

    public func run(id: UUID) throws -> RunSnapshot {
        guard let row = try query(
            "SELECT id, session_id, prompt, response, state, started_at, finished_at, configuration FROM runs WHERE id = ?",
            [.text(id.uuidString)]
        ).first else { throw LatheError.notFound(L10n.text("storage.run.notFound", table: "StorageErrors")) }
        return try decodeRun(row)
    }

    public func listProviderProfiles() throws -> [ProviderProfile] {
        try query("SELECT snapshot FROM provider_profiles ORDER BY rowid LIMIT 64").map {
            try decode(string($0[0]))
        }
    }

    /// Profile metadata contains connection settings, never an API credential.
    public func saveProviderProfile(_ profile: ProviderProfile) throws {
        try profile.validate()
        try transaction {
            let existing = try query("SELECT id FROM provider_profiles WHERE id = ?", [.text(profile.id.uuidString)])
            if existing.isEmpty {
                guard try integer(query("SELECT COUNT(*) FROM provider_profiles")[0][0]) < 64 else {
                    throw LatheError.invalidRequest(L10n.text("storage.provider.profileLimit", table: "StorageErrors"))
                }
            }
            try execute(
                "INSERT INTO provider_profiles (id, snapshot) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET snapshot = excluded.snapshot",
                [.text(profile.id.uuidString), .text(try encode(profile))]
            )
        }
    }

    public func invocation(id: UUID) throws -> ToolInvocationSnapshot {
        guard let row = try query("SELECT snapshot FROM tool_invocations WHERE id = ?", [.text(id.uuidString)]).first else {
            throw LatheError.notFound(L10n.text("storage.tool.notFound", table: "StorageErrors"))
        }
        return try decode(string(row[0]))
    }

    public func saveModelHistory(runID: UUID, blobID: String) throws {
        guard BlobStore.validID(blobID) else { throw LatheError.invalidRequest(L10n.text("storage.blob.invalidID", table: "StorageErrors")) }
        try transaction {
            _ = try run(id: runID)
            try execute(
                "INSERT INTO model_histories (run_id, blob_id) VALUES (?, ?) ON CONFLICT(run_id) DO UPDATE SET blob_id = excluded.blob_id",
                [.text(runID.uuidString), .text(blobID)]
            )
        }
    }

    public func modelHistory(runID: UUID) throws -> String? {
        _ = try run(id: runID)
        guard let row = try query("SELECT blob_id FROM model_histories WHERE run_id = ?", [.text(runID.uuidString)]).first else { return nil }
        let id = try string(row[0])
        guard BlobStore.validID(id) else { throw LatheError.storage(L10n.text("storage.blob.invalidStoredID", table: "StorageErrors")) }
        return id
    }

    public func invocations(runID: UUID) throws -> [ToolInvocationSnapshot] {
        _ = try run(id: runID)
        return try query("SELECT snapshot FROM tool_invocations WHERE run_id = ? ORDER BY rowid LIMIT 64", [.text(runID.uuidString)]).map {
            try decode(string($0[0]))
        }
    }

    /// State projection and replay event are committed together. A terminal
    /// receipt may arrive after run cancellation, but can never authorize replay.
    public func saveInvocation(_ snapshot: ToolInvocationSnapshot) throws {
        try transaction {
            let run = try run(id: snapshot.runID)
            guard snapshot.arguments.utf8.count <= 32 * 1_024,
                  snapshot.summary.utf8.count <= 2 * 1_024,
                  (snapshot.output?.utf8.count ?? 0) <= 8 * 1_024,
                  snapshot.callID.utf8.count <= 256, snapshot.name.utf8.count <= 128,
                  BlobStore.validID(snapshot.requestHash),
                  snapshot.beforeBlobID.map(BlobStore.validID) ?? true,
                  snapshot.blobID.map(BlobStore.validID) ?? true else {
                throw LatheError.invalidRequest(L10n.text("storage.tool.metadataTooLarge", table: "StorageErrors"))
            }
            if let row = try query("SELECT snapshot FROM tool_invocations WHERE id = ?", [.text(snapshot.id.uuidString)]).first {
                let previous: ToolInvocationSnapshot = try decode(string(row[0]))
                guard previous.runID == snapshot.runID, previous.callID == snapshot.callID,
                      previous.name == snapshot.name, previous.arguments == snapshot.arguments,
                      previous.requestHash == snapshot.requestHash, previous.summary == snapshot.summary,
                      previous.effect == snapshot.effect, previous.createdAt == snapshot.createdAt else {
                    throw LatheError.conflict(L10n.text("storage.tool.immutableRequest", table: "StorageErrors"))
                }
                if previous == snapshot { return }
                var withBaseline = previous
                withBaseline.beforeBlobID = snapshot.beforeBlobID
                let capturesBaseline = previous.state == .executing && snapshot.effect == .write &&
                    previous.beforeBlobID == nil && snapshot.beforeBlobID != nil && snapshot == withBaseline
                guard previous.beforeBlobID == snapshot.beforeBlobID || capturesBaseline else {
                    throw LatheError.conflict(L10n.text("storage.tool.baselineAlreadyRecorded", table: "StorageErrors"))
                }
                guard !isTerminal(previous.state), capturesBaseline || validTransition(from: previous.state, to: snapshot.state) else {
                    throw LatheError.conflict(L10n.text("storage.tool.invalidStateTransition", table: "StorageErrors"))
                }
                guard run.state == .running || isTerminal(snapshot.state) else {
                    throw LatheError.conflict(L10n.text("storage.tool.finishedRunCannotExecute", table: "StorageErrors"))
                }
            } else {
                guard run.state == .running else {
                    throw LatheError.conflict(L10n.text("storage.tool.finishedRunCannotAdd", table: "StorageErrors"))
                }
                guard snapshot.state == .pendingApproval || snapshot.state == .approved || snapshot.state == .denied else {
                    throw LatheError.invalidRequest(L10n.text("storage.tool.permissionDecisionRequired", table: "StorageErrors"))
                }
                guard snapshot.beforeBlobID == nil else {
                    throw LatheError.invalidRequest(L10n.text("storage.tool.unapprovedBaseline", table: "StorageErrors"))
                }
                guard try integer(query("SELECT COUNT(*) FROM tool_invocations WHERE run_id = ?", [.text(snapshot.runID.uuidString)])[0][0]) < 64 else {
                    throw LatheError.invalidRequest(L10n.text("storage.tool.invocationLimit", table: "StorageErrors"))
                }
            }
            try writeInvocation(snapshot)
        }
    }

    /// Normal cancellation invalidates consent only; the runner must supply an
    /// accurate terminal receipt after its owned process has been cleaned up.
    public func invalidatePendingInvocations(runID: UUID) throws {
        try transaction {
            for var snapshot in try invocations(runID: runID) where snapshot.state == .pendingApproval || snapshot.state == .approved {
                snapshot.state = .cancelled
                snapshot.output = L10n.text("storage.tool.approvalCancelledOnFinish", table: "StorageErrors")
                try writeInvocation(snapshot)
            }
        }
    }

    private func isTerminal(_ state: ToolInvocationState) -> Bool {
        switch state {
        case .pendingApproval, .approved, .executing: false
        case .completed, .denied, .failed, .cancelled, .unknown: true
        }
    }

    private func validTransition(from: ToolInvocationState, to: ToolInvocationState) -> Bool {
        switch from {
        case .pendingApproval: to == .approved || to == .denied || to == .cancelled
        case .approved: to == .executing || to == .cancelled || to == .failed
        case .executing: isTerminal(to)
        case .completed, .denied, .failed, .cancelled, .unknown: false
        }
    }

    private func writeInvocation(_ snapshot: ToolInvocationSnapshot) throws {
        let run = try run(id: snapshot.runID)
        let now = storedTimestamp()
        try execute(
            "INSERT INTO tool_invocations (id, run_id, call_id, state, snapshot) VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET state = excluded.state, snapshot = excluded.snapshot",
            [.text(snapshot.id.uuidString), .text(snapshot.runID.uuidString), .text(snapshot.callID), .text(snapshot.state.rawValue), .text(try encode(snapshot))]
        )
        try touch(run.sessionID, at: now)
        try insertEvent(sessionID: run.sessionID, runID: run.id, kind: .toolUpdated, text: snapshot.id.uuidString, timestamp: now)
    }

    public func createSession(title: String, workspacePath: String) throws -> SessionSnapshot {
        let now = storedTimestamp()
        let session = SessionSnapshot(title: title, workspacePath: workspacePath, createdAt: now, updatedAt: now)
        try transaction {
            try execute(
                "INSERT INTO sessions (id, title, workspace_path, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                [.text(session.id.uuidString), .text(title), .text(workspacePath), .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)]
            )
            try insertEvent(sessionID: session.id, kind: .sessionCreated, timestamp: now)
        }
        return session
    }

    /// The request key and run/event are committed together. Reusing a key for
    /// another payload never starts a second run, including after restart.
    public func submit(sessionID: UUID, prompt: String, requestID: UUID, configuration: RunConfiguration? = nil) throws -> (run: RunSnapshot, created: Bool) {
        try configuration?.validate()
        return try transaction {
            if let existing = try query(
                "SELECT session_id, prompt, run_id FROM requests WHERE request_id = ?",
                [.text(requestID.uuidString)]
            ).first {
                guard try uuid(existing[0]) == sessionID, try string(existing[1]) == prompt else {
                    throw LatheError.conflict(L10n.text("storage.request.identityConflict", table: "StorageErrors"))
                }
                let previous = try run(id: uuid(existing[2]))
                guard previous.configuration == configuration else {
                    throw LatheError.conflict(L10n.text("storage.request.configurationConflict", table: "StorageErrors"))
                }
                return (previous, false)
            }
            if let profile = configuration?.profile {
                guard try listProviderProfiles().contains(profile) else {
                    throw LatheError.invalidRequest(L10n.text("storage.request.staleProfile", table: "StorageErrors"))
                }
            }
            guard !(try query("SELECT id FROM sessions WHERE id = ?", [.text(sessionID.uuidString)])).isEmpty else {
                throw LatheError.notFound(L10n.text("storage.session.notFound", table: "StorageErrors"))
            }
            guard (try query("SELECT id FROM runs WHERE session_id = ? AND state = 'running'", [.text(sessionID.uuidString)])).isEmpty else {
                throw LatheError.conflict(L10n.text("storage.session.alreadyRunning", table: "StorageErrors"))
            }
            let run = RunSnapshot(sessionID: sessionID, prompt: prompt, startedAt: storedTimestamp(), configuration: configuration)
            try execute(
                "INSERT INTO runs (id, session_id, prompt, response, state, started_at, configuration) VALUES (?, ?, ?, '', 'running', ?, ?)",
                [.text(run.id.uuidString), .text(sessionID.uuidString), .text(prompt), .real(run.startedAt.timeIntervalSince1970), try configuration.map { .text(try encode($0)) } ?? .null]
            )
            try execute(
                "INSERT INTO requests (request_id, session_id, prompt, run_id) VALUES (?, ?, ?, ?)",
                [.text(requestID.uuidString), .text(sessionID.uuidString), .text(prompt), .text(run.id.uuidString)]
            )
            try touch(sessionID, at: run.startedAt)
            try insertEvent(sessionID: sessionID, runID: run.id, kind: .runStarted, timestamp: run.startedAt)
            return (run, true)
        }
    }

    @discardableResult
    public func append(runID: UUID, text: String) throws -> Bool {
        try transaction {
            let run = try run(id: runID)
            guard run.state == .running else { return false }
            let now = storedTimestamp()
            try execute("UPDATE runs SET response = response || ? WHERE id = ?", [.text(text), .text(runID.uuidString)])
            try touch(run.sessionID, at: now)
            try insertEvent(sessionID: run.sessionID, runID: runID, kind: .textDelta, text: text, timestamp: now)
            return true
        }
    }

    @discardableResult
    public func finish(runID: UUID, state: RunState, reason: String? = nil) throws -> RunSnapshot {
        guard state != .running else { throw LatheError.invalidRequest(L10n.text("storage.run.terminalStateRequired", table: "StorageErrors")) }
        return try transaction {
            var run = try run(id: runID)
            guard run.state == .running else { return run }
            let now = storedTimestamp()
            try execute(
                "UPDATE runs SET state = ?, finished_at = ? WHERE id = ?",
                [.text(state.rawValue), .real(now.timeIntervalSince1970), .text(runID.uuidString)]
            )
            try touch(run.sessionID, at: now)
            let kind: EventKind = switch state {
            case .completed: .runCompleted
            case .cancelled: .runCancelled
            case .interrupted: .runInterrupted
            case .failed: .runFailed
            case .running: fatalError("Guarded above")
            }
            try insertEvent(sessionID: run.sessionID, runID: runID, kind: kind, text: reason, timestamp: now)
            run.state = state
            run.finishedAt = now
            return run
        }
    }

    /// Called once by a newly started engine after acquiring the process lock.
    /// No model requests are resumed automatically.
    public func recoverInterruptedRuns() throws {
        try transaction {
            // Include terminal runs too: a process can die after the run cancellation
            // commits but before its final tool receipt is recorded.
            let pending = try query("SELECT snapshot FROM tool_invocations WHERE state IN ('pendingApproval', 'approved', 'executing') ORDER BY rowid")
            for row in pending {
                var invocation: ToolInvocationSnapshot = try decode(string(row[0]))
                invocation.state = invocation.state == .executing ? .unknown : .cancelled
                invocation.output = invocation.state == .unknown
                    ? L10n.text("storage.recovery.toolOutcomeUnknown", table: "StorageErrors")
                    : L10n.text("storage.recovery.approvalCancelled", table: "StorageErrors")
                try writeInvocation(invocation)
            }
            let ids = try query("SELECT id FROM runs WHERE state = 'running' ORDER BY started_at, rowid")
            for row in ids {
                let run = try run(id: uuid(row[0]))
                let now = storedTimestamp()
                try execute("UPDATE runs SET state = 'interrupted', finished_at = ? WHERE id = ?", [.real(now.timeIntervalSince1970), .text(run.id.uuidString)])
                try touch(run.sessionID, at: now)
                try insertEvent(sessionID: run.sessionID, runID: run.id, kind: .runInterrupted, text: L10n.text("storage.recovery.runInterrupted", table: "StorageErrors"), timestamp: now)
            }
        }
    }

    public func events(after cursor: Int64, sessionID: UUID?, runID: UUID? = nil, limit: Int) throws -> EventPage {
        guard cursor >= 0, (1...1_024).contains(limit) else {
            throw LatheError.invalidRequest(L10n.text("storage.events.invalidPage", table: "StorageErrors"))
        }
        if let sessionID,
           try query("SELECT id FROM sessions WHERE id = ?", [.text(sessionID.uuidString)]).isEmpty {
            throw LatheError.notFound(L10n.text("storage.session.notFound", table: "StorageErrors"))
        }
        if let runID {
            let run = try run(id: runID)
            guard sessionID == nil || sessionID == run.sessionID else {
                throw LatheError.invalidRequest(L10n.text("storage.events.sessionMismatch", table: "StorageErrors"))
            }
        }
        let highWater = try integer(query("SELECT COALESCE(MAX(sequence), 0) FROM events")[0][0])
        var sql = "SELECT sequence, session_id, run_id, kind, text, timestamp FROM events WHERE sequence > ? AND sequence <= ?"
        var values: [Value] = [.integer(cursor), .integer(highWater)]
        if let sessionID { sql += " AND session_id = ?"; values.append(.text(sessionID.uuidString)) }
        if let runID { sql += " AND run_id = ?"; values.append(.text(runID.uuidString)) }
        sql += " ORDER BY sequence LIMIT ?"
        values.append(.integer(Int64(limit)))
        let events = try query(sql, values).map { row -> EngineEvent in
            guard let kind = EventKind(rawValue: try string(row[3])) else { throw LatheError.storage(L10n.text("storage.events.invalidKind", table: "StorageErrors")) }
            return EngineEvent(
                sequence: try integer(row[0]), sessionID: try uuid(row[1]),
                runID: try optionalString(row[2]).map { try uuid(.text($0)) }, kind: kind,
                text: try optionalString(row[4]), timestamp: try date(row[5])
            )
        }
        let next = events.count == limit ? events.last!.sequence : max(cursor, highWater)
        return EventPage(events: events, nextCursor: next)
    }

    private func migrate() throws {
        let version = try integer(query("PRAGMA user_version")[0][0])
        guard version <= 2 else { throw LatheError.storage(L10n.text("storage.database.newerSchema", table: "StorageErrors")) }
        guard version < 2 else { return }
        // Rebuild the v1 CHECK constraint without rewriting the request/event
        // foreign keys. Restore enforcement even when migration rolls back.
        try execute("PRAGMA foreign_keys = OFF")
        defer { try? execute("PRAGMA foreign_keys = ON") }
        try transaction {
            if version == 0 {
                try execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, title TEXT NOT NULL, workspace_path TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL)")
            }
            try execute("CREATE TABLE runs_v2 (id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id), prompt TEXT NOT NULL, response TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('running','completed','cancelled','interrupted','failed')), started_at REAL NOT NULL, finished_at REAL, configuration TEXT)")
            if version == 1 {
                try execute("INSERT INTO runs_v2 (rowid, id, session_id, prompt, response, state, started_at, finished_at) SELECT rowid, id, session_id, prompt, response, state, started_at, finished_at FROM runs")
                try execute("DROP TABLE runs")
            }
            try execute("ALTER TABLE runs_v2 RENAME TO runs")
            try execute("CREATE UNIQUE INDEX one_running_run_per_session ON runs(session_id) WHERE state = 'running'")
            if version == 0 {
                try execute("CREATE TABLE requests (request_id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id), prompt TEXT NOT NULL, run_id TEXT NOT NULL UNIQUE REFERENCES runs(id))")
                try execute("CREATE TABLE events (sequence INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL REFERENCES sessions(id), run_id TEXT REFERENCES runs(id), kind TEXT NOT NULL, text TEXT, timestamp REAL NOT NULL)")
                try execute("CREATE INDEX session_events ON events(session_id, sequence)")
            }
            try execute("CREATE TABLE provider_profiles (id TEXT PRIMARY KEY, snapshot TEXT NOT NULL)")
            try execute("CREATE TABLE model_histories (run_id TEXT PRIMARY KEY REFERENCES runs(id), blob_id TEXT NOT NULL)")
            try execute("CREATE TABLE tool_invocations (id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(id), call_id TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('pendingApproval','approved','executing','completed','denied','failed','cancelled','unknown')), snapshot TEXT NOT NULL, UNIQUE(run_id, call_id))")
            try execute("CREATE INDEX run_invocations ON tool_invocations(run_id)")
            guard try query("PRAGMA foreign_key_check").isEmpty else {
                throw LatheError.storage(L10n.text("storage.database.migrationIntegrityFailed", table: "StorageErrors"))
            }
            try execute("PRAGMA user_version = 2")
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func decode<T: Decodable>(_ value: String) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: Data(value.utf8)) }
        catch { throw LatheError.storage(L10n.text("storage.run.metadataUnreadable", table: "StorageErrors")) }
    }

    private func touch(_ sessionID: UUID, at date: Date) throws {
        try execute("UPDATE sessions SET updated_at = ? WHERE id = ?", [.real(date.timeIntervalSince1970), .text(sessionID.uuidString)])
    }

    // Date uses a different reference epoch internally. Normalize once to our
    // persisted seconds so an immediate result equals its SQLite replay exactly.
    private func storedTimestamp() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970)
    }

    private func insertEvent(sessionID: UUID, runID: UUID? = nil, kind: EventKind, text: String? = nil, timestamp: Date) throws {
        try execute(
            "INSERT INTO events (session_id, run_id, kind, text, timestamp) VALUES (?, ?, ?, ?, ?)",
            [.text(sessionID.uuidString), runID.map { .text($0.uuidString) } ?? .null, .text(kind.rawValue), text.map(Value.text) ?? .null, .real(timestamp.timeIntervalSince1970)]
        )
    }

    private func decodeRun(_ row: [Value]) throws -> RunSnapshot {
        guard let state = RunState(rawValue: try string(row[4])) else { throw LatheError.storage(L10n.text("storage.run.invalidState", table: "StorageErrors")) }
        let finishedAt: Date? = if case .null = row[6] { nil } else { try date(row[6]) }
        let configuration: RunConfiguration? = try optionalString(row[7]).map { try decode($0) }
        return RunSnapshot(id: try uuid(row[0]), sessionID: try uuid(row[1]), prompt: try string(row[2]), response: try string(row[3]), state: state, startedAt: try date(row[5]), finishedAt: finishedAt, configuration: configuration)
    }

    private enum Value {
        case text(String), integer(Int64), real(Double), null
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String, _ values: [Value] = []) throws {
        _ = try query(sql, values)
    }

    private func query(_ sql: String, _ values: [Value] = []) throws -> [[Value]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw LatheError.storage(L10n.format("storage.database.prepareFailed", table: "StorageErrors", databaseDetail()))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32 = switch value {
            case .text(let text):
                text.withCString { sqlite3_bind_text(statement, index, $0, Int32(text.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            case .integer(let number): sqlite3_bind_int64(statement, index, number)
            case .real(let number): sqlite3_bind_double(statement, index, number)
            case .null: sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw LatheError.storage(L10n.format("storage.database.bindFailed", table: "StorageErrors", databaseDetail())) }
        }
        var rows: [[Value]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw LatheError.storage(L10n.format("storage.database.operationFailed", table: "StorageErrors", databaseDetail())) }
            var row: [Value] = []
            for index in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, index)))
                case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(statement, index)))
                case SQLITE_TEXT:
                    guard let bytes = sqlite3_column_text(statement, index) else { throw LatheError.storage(L10n.format("storage.database.textReadFailed", table: "StorageErrors", databaseDetail())) }
                    row.append(.text(String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)))
                case SQLITE_NULL: row.append(.null)
                default: throw LatheError.storage(L10n.text("storage.database.unsupportedValue", table: "StorageErrors"))
                }
            }
            rows.append(row)
        }
    }

    private func string(_ value: Value) throws -> String {
        guard case .text(let text) = value else { throw LatheError.storage(L10n.text("storage.value.invalidText", table: "StorageErrors")) }
        return text
    }

    private func optionalString(_ value: Value) throws -> String? {
        if case .null = value { return nil }
        return try string(value)
    }

    private func integer(_ value: Value) throws -> Int64 {
        guard case .integer(let number) = value else { throw LatheError.storage(L10n.text("storage.value.invalidInteger", table: "StorageErrors")) }
        return number
    }

    private func uuid(_ value: Value) throws -> UUID {
        guard let id = UUID(uuidString: try string(value)) else { throw LatheError.storage(L10n.text("storage.value.invalidIdentifier", table: "StorageErrors")) }
        return id
    }

    private func date(_ value: Value) throws -> Date {
        switch value {
        case .real(let number): return Date(timeIntervalSince1970: number)
        case .integer(let number): return Date(timeIntervalSince1970: Double(number))
        default: throw LatheError.storage(L10n.text("storage.value.invalidDate", table: "StorageErrors"))
        }
    }

    private func databaseDetail() -> String {
        return database.map { String(cString: sqlite3_errmsg($0)) } ?? L10n.text("storage.database.noConnection", table: "StorageErrors")
    }
}
